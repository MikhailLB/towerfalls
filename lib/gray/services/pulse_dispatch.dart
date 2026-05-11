import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'runtime_cache.dart';
import 'secure_http.dart';

/// Notification channel ID used for ALL pushes the gray flow surfaces.
/// MUST match `com.google.firebase.messaging.default_notification_channel_id`
/// in `AndroidManifest.xml` — otherwise data-only background pushes silently
/// fail to display on Android 13+ (the OS drops them with a "no channel"
/// error and the user never sees the notification).
const String pulseChannelId = 'gray_pulse_channel';
const String pulseChannelLabel = 'App Updates';
const String pulseIconRes = '@drawable/ic_pulse_notification';

@pragma('vm:entry-point')
Future<void> _pulseBackgroundHandler(RemoteMessage _) async {
  // Background isolate — kept empty intentionally; the OS displays the
  // notification on its own and we read [data.url] when the user taps it.
}

/// FCM + flutter_local_notifications wrapper. Initialises gracefully when
/// `google-services.json` (or its iOS equivalent) is missing — in that case
/// `bootstrap` swallows the error and [askConsent] short-circuits to false.
class PulseDispatch {
  final FlutterLocalNotificationsPlugin _tray =
      FlutterLocalNotificationsPlugin();
  final RuntimeCache _cache;
  FirebaseMessaging? _messaging;
  String? _token;
  bool _ready = false;
  Future<bool>? _consentInFlight;

  void Function(String url)? onPushDestination;
  void Function(String token)? onTokenRotated;

  PulseDispatch(this._cache);

  String? get token => _token;
  bool get ready => _ready;

  Future<void> bootstrap() async {
    if (_ready) return;
    try {
      try {
        await Firebase.initializeApp();
      } catch (err) {
        if (kDebugMode) {
          debugPrint('[PULSE] Firebase init skipped: $err');
        }
        return;
      }

      _messaging = FirebaseMessaging.instance;
      FirebaseMessaging.onBackgroundMessage(_pulseBackgroundHandler);

      await _setupTray();

      try {
        _token = await _messaging!.getToken();
      } catch (err) {
        if (kDebugMode) debugPrint('[PULSE] getToken failed: $err');
      }

      _messaging!.onTokenRefresh.listen((fresh) {
        _token = fresh;
        onTokenRotated?.call(fresh);
      });

      FirebaseMessaging.onMessage.listen(_onForeground);
      FirebaseMessaging.onMessageOpenedApp.listen(_onTapInBackground);

      final cold = await _messaging!.getInitialMessage();
      if (cold != null) _onColdStart(cold);

      _ready = true;
      if (kDebugMode) {
        debugPrint(
          '[PULSE] bootstrap OK, token=${_token == null ? 'null' : '${_token!.substring(0, _token!.length.clamp(0, 12))}…'}',
        );
      }
    } catch (err, st) {
      if (kDebugMode) {
        debugPrint('[PULSE] bootstrap failed: $err');
        debugPrint('$st');
      }
    }
  }

  Future<void> _setupTray() async {
    const androidInit = AndroidInitializationSettings(pulseIconRes);
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _tray.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: (resp) {
        final payload = resp.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map && decoded['url'] is String) {
            final url = decoded['url'] as String;
            if (url.isNotEmpty) onPushDestination?.call(url);
          }
        } catch (_) {}
      },
    );

    if (Platform.isAndroid) {
      final impl = _tray.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await impl?.createNotificationChannel(
        const AndroidNotificationChannel(
          pulseChannelId,
          pulseChannelLabel,
          description: 'Real-time updates and offers.',
          importance: Importance.high,
        ),
      );
    }
  }

  Future<bool> askConsent() async {
    if (_messaging == null) {
      if (kDebugMode) {
        debugPrint('[PULSE] askConsent skipped — Firebase missing');
      }
      return false;
    }
    final pending = _consentInFlight;
    if (pending != null) return pending;

    final flow = _askConsentImpl();
    _consentInFlight = flow;
    try {
      return await flow;
    } finally {
      _consentInFlight = null;
    }
  }

  Future<bool> _askConsentImpl() async {
    try {
      if (Platform.isAndroid) {
        return await _consentAndroid();
      }
      return await _consentIos();
    } catch (err, st) {
      if (kDebugMode) {
        debugPrint('[PULSE] consent error: $err');
        debugPrint('$st');
      }
      return false;
    }
  }

  // 1 year — effectively "never show again" without burning a magic flag.
  static const int _systemDeniedCooldownSeconds = 365 * 24 * 3600;

  Future<void> _markSystemDenied() async {
    await _cache.writePushConsent(false);
    await _cache.writePushCooldownUntil(
      (DateTime.now().millisecondsSinceEpoch ~/ 1000) +
          _systemDeniedCooldownSeconds,
    );
  }

  Future<bool> _consentAndroid() async {
    final impl = _tray.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (impl == null) {
      return _consentIos();
    }
    final already = await impl.areNotificationsEnabled();
    if (already == true) {
      await _cache.writePushConsent(true);
      return true;
    }
    final granted = await impl.requestNotificationsPermission();
    if (granted == true) {
      await _cache.writePushConsent(true);
      return true;
    }
    // The user passed our offer screen ("Accept") but said no to the OS
    // prompt — or the OS silently refused after 2 prior denials. In either
    // case the system prompt is no longer reachable, so per the spec we
    // suppress our offer screen for the foreseeable future.
    await _markSystemDenied();
    return false;
  }

  Future<bool> _consentIos() async {
    final settings = await _messaging!.getNotificationSettings();
    final status = settings.authorizationStatus;

    if (status == AuthorizationStatus.denied) {
      // OS already remembers a hard "no" — the system prompt cannot be
      // shown again. Bury our offer screen.
      await _markSystemDenied();
      return false;
    }

    if (status != AuthorizationStatus.notDetermined) {
      final ok = status == AuthorizationStatus.authorized ||
          status == AuthorizationStatus.provisional;
      await _cache.writePushConsent(ok);
      return ok;
    }

    final result = await _messaging!.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    final ok = result.authorizationStatus == AuthorizationStatus.authorized ||
        result.authorizationStatus == AuthorizationStatus.provisional;
    if (!ok && result.authorizationStatus == AuthorizationStatus.denied) {
      await _markSystemDenied();
      return false;
    }
    await _cache.writePushConsent(ok);
    return ok;
  }

  /// Returns true when it still makes sense to show the in-app
  /// "allow notifications" offer. Mirrors the iOS-side gate added on the
  /// gray-part-ios branch: any state other than "fresh / not asked" means
  /// the offer screen would either be redundant (already authorised) or
  /// pointless (system prompt unreachable).
  Future<bool> shouldOfferConsent() async {
    final m = _messaging;
    if (m == null) return false;
    try {
      if (Platform.isAndroid) {
        final impl = _tray.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        if (impl == null) return true;
        final enabled = await impl.areNotificationsEnabled();
        return enabled != true;
      }
      final settings = await m.getNotificationSettings();
      final status = settings.authorizationStatus;
      if (status == AuthorizationStatus.notDetermined) return true;
      if (status == AuthorizationStatus.denied) {
        await _markSystemDenied();
      }
      return false;
    } catch (err) {
      if (kDebugMode) debugPrint('[PULSE] shouldOfferConsent error: $err');
      return false;
    }
  }

  void _onForeground(RemoteMessage message) async {
    final notif = message.notification;
    if (notif == null) return;

    String? imageUrl;
    if (Platform.isAndroid) {
      imageUrl = notif.android?.imageUrl;
    } else {
      imageUrl = notif.apple?.imageUrl;
    }

    AndroidNotificationDetails? androidDetails;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      final bytes = await _downloadImage(imageUrl);
      if (bytes != null) {
        androidDetails = AndroidNotificationDetails(
          pulseChannelId,
          pulseChannelLabel,
          importance: Importance.high,
          priority: Priority.high,
          icon: pulseIconRes,
          styleInformation: BigPictureStyleInformation(
            ByteArrayAndroidBitmap(bytes),
            largeIcon:
                const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
          ),
        );
      }
    }

    androidDetails ??= const AndroidNotificationDetails(
      pulseChannelId,
      pulseChannelLabel,
      importance: Importance.high,
      priority: Priority.high,
      icon: pulseIconRes,
    );

    final payload =
        message.data.isNotEmpty ? jsonEncode(message.data) : null;

    await _tray.show(
      notif.hashCode,
      notif.title,
      notif.body,
      NotificationDetails(
        android: androidDetails,
        iOS: const DarwinNotificationDetails(),
      ),
      payload: payload,
    );
  }

  void _onColdStart(RemoteMessage message) {
    final url = message.data['url'] as String?;
    if (url != null && url.isNotEmpty) {
      _cache.stashOneShotPush(url);
    }
  }

  void _onTapInBackground(RemoteMessage message) {
    final url = message.data['url'] as String?;
    if (url != null && url.isNotEmpty) {
      onPushDestination?.call(url);
    }
  }

  Future<Uint8List?> _downloadImage(String url) async {
    try {
      final response = await secureHttp
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode == 200) return response.bodyBytes;
    } catch (_) {}
    return null;
  }
}
