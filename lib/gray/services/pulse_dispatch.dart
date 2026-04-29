import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'runtime_cache.dart';
import 'secure_http.dart';

const String pulseChannelId = 'tf_pulse_channel';
const String pulseChannelLabel = 'Tower Falls Updates';
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

      if (Platform.isIOS) {
        try {
          await _messaging!.setForegroundNotificationPresentationOptions(
            alert: true,
            badge: true,
            sound: true,
          );
        } catch (err) {
          if (kDebugMode) {
            debugPrint('[PULSE] foreground options skipped: $err');
          }
        }
        await _waitForApnsToken();
      }

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

  // Number of poll attempts when waiting for the iOS APNs token. Spaced ~600ms
  // apart, which gives ~4.2s total — enough for typical TestFlight cold starts
  // without blocking the gray flow indefinitely.
  static const int _apnsRetries = 7;
  static const Duration _apnsBackoff = Duration(milliseconds: 600);

  Future<void> _waitForApnsToken() async {
    final m = _messaging;
    if (m == null) return;
    for (var attempt = 0; attempt < _apnsRetries; attempt++) {
      try {
        final apns = await m.getAPNSToken();
        if (apns != null && apns.isNotEmpty) {
          if (kDebugMode) debugPrint('[PULSE] APNs token ready');
          return;
        }
      } catch (err) {
        if (kDebugMode) debugPrint('[PULSE] APNs poll error: $err');
      }
      await Future.delayed(_apnsBackoff);
    }
    if (kDebugMode) debugPrint('[PULSE] APNs token not received in time');
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
          description: 'Tower Falls real-time updates',
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
    final ok = granted ?? false;
    await _cache.writePushConsent(ok);
    return ok;
  }

  Future<bool> _consentIos() async {
    final settings = await _messaging!.getNotificationSettings();
    if (settings.authorizationStatus != AuthorizationStatus.notDetermined) {
      final ok =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
              settings.authorizationStatus == AuthorizationStatus.provisional;
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
    await _cache.writePushConsent(ok);
    return ok;
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
