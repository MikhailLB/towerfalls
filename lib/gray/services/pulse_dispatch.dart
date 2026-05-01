import 'dart:convert';
import 'dart:io';

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
      // Firebase.initializeApp() is already called in main.dart#_bootFirebase
      // before runApp. We must NOT call it again here — re-initialising raises
      // "[core/duplicate-app]" in some firebase_core versions and the previous
      // implementation caught that exception and silently `return`-ed, which
      // skipped onMessage / onMessageOpenedApp registration entirely. That was
      // exactly why notification taps never reached Dart on iOS.
      _messaging = FirebaseMessaging.instance;

      FirebaseMessaging.onBackgroundMessage(_pulseBackgroundHandler);
      await _setupTray();

      // Set foreground presentation options unconditionally (matches GR). The
      // call is a no-op on Android.
      try {
        await _messaging!.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
      } catch (err) {
        debugPrint('[PULSE] foreground options skipped: $err');
      }

      // Attach listeners BEFORE awaiting any token / cold-start work so we
      // never miss a foreground push that arrives during bootstrap.
      _messaging!.onTokenRefresh.listen((fresh) {
        _token = fresh;
        debugPrint('[PULSE] onTokenRefresh');
        onTokenRotated?.call(fresh);
      });
      FirebaseMessaging.onMessage.listen(_onForeground);
      FirebaseMessaging.onMessageOpenedApp.listen(_onTapInBackground);

      if (Platform.isIOS) {
        await _waitForApnsToken();
      }

      try {
        _token = await _messaging!.getToken();
      } catch (err) {
        debugPrint('[PULSE] getToken failed: $err');
      }

      try {
        final cold = await _messaging!.getInitialMessage();
        if (cold != null) await _onColdStart(cold);
      } catch (err) {
        debugPrint('[PULSE] getInitialMessage failed: $err');
      }

      _ready = true;
      debugPrint(
        '[PULSE] bootstrap OK, token=${_token == null ? 'null' : '${_token!.substring(0, _token!.length.clamp(0, 12))}…'}',
      );
    } catch (err, st) {
      debugPrint('[PULSE] bootstrap failed: $err');
      debugPrint('$st');
    }
  }

  Future<String?> refreshToken({bool notify = true}) async {
    final m = _messaging;
    if (m == null) {
      debugPrint('[PULSE] refreshToken skipped — Firebase missing');
      return null;
    }
    try {
      if (Platform.isIOS) {
        await _waitForApnsToken();
      }
      _token = await m.getToken().timeout(const Duration(seconds: 8));
      final fresh = _token;
      debugPrint('[PULSE] refreshToken=${fresh == null ? 'null' : 'present'}');
      if (notify && fresh != null && fresh.isNotEmpty) {
        onTokenRotated?.call(fresh);
      }
      return fresh;
    } catch (err, st) {
      debugPrint('[PULSE] refreshToken failed: $err\n$st');
      return null;
    }
  }

  Future<String?> refreshTokenAfterConsent({bool notify = true}) async {
    final m = _messaging;
    if (m == null) {
      debugPrint('[PULSE] refreshTokenAfterConsent skipped — Firebase missing');
      return null;
    }
    try {
      if (Platform.isIOS) {
        // requestPermission() triggers registerForRemoteNotifications via
        // Firebase Messaging swizzling. Give APNs more time here than at cold
        // boot because the user has just explicitly accepted notifications.
        await _waitForApnsToken(
          retries: 14,
          backoff: const Duration(milliseconds: 700),
        );
      }
      _token = await m.getToken().timeout(const Duration(seconds: 10));
      final fresh = _token;
      debugPrint(
          '[PULSE] refreshTokenAfterConsent=${fresh == null ? 'null' : 'present'}');
      if (notify && fresh != null && fresh.isNotEmpty) {
        onTokenRotated?.call(fresh);
      }
      return fresh;
    } catch (err, st) {
      debugPrint('[PULSE] refreshTokenAfterConsent failed: $err\n$st');
      return null;
    }
  }

  // Number of poll attempts when waiting for the iOS APNs token. Spaced ~600ms
  // apart, which gives ~4.2s total — enough for typical TestFlight cold starts
  // without blocking the gray flow indefinitely.
  static const int _apnsRetries = 7;
  static const Duration _apnsBackoff = Duration(milliseconds: 600);

  Future<void> _waitForApnsToken({
    int retries = _apnsRetries,
    Duration backoff = _apnsBackoff,
  }) async {
    final m = _messaging;
    if (m == null) return;
    for (var attempt = 1; attempt <= retries; attempt++) {
      try {
        final apns = await m.getAPNSToken();
        debugPrint(
          '[PULSE] APNs token attempt $attempt/$retries: '
          '${apns == null || apns.isEmpty ? 'null' : 'present'}',
        );
        if (apns != null && apns.isNotEmpty) {
          debugPrint('[PULSE] APNs token ready');
          return;
        }
      } catch (err) {
        debugPrint('[PULSE] APNs poll error: $err');
      }
      await Future.delayed(backoff);
    }
    debugPrint('[PULSE] APNs token not received in time');
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
            if (url.isNotEmpty) _dispatchUrl(url, source: 'tray');
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
    final status = settings.authorizationStatus;

    if (status == AuthorizationStatus.denied) {
      // iOS permanently denied — the system prompt cannot be shown again.
      // Write a 1-year cooldown so the offer screen never appears again
      // (user must re-enable manually in system Settings).
      await _cache.writePushCooldownUntil(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 + 365 * 24 * 3600,
      );
      await _cache.writePushConsent(false);
      debugPrint('[PULSE] iOS notifications permanently denied — suppressing prompt');
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
      // System prompt shown and user clicked "Don't Allow" — suppress future prompts.
      await _cache.writePushCooldownUntil(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 + 365 * 24 * 3600,
      );
    }
    await _cache.writePushConsent(ok);
    return ok;
  }

  void _onForeground(RemoteMessage message) async {
    debugPrint(
      '[PULSE] foreground msg id=${message.messageId} '
      'notif=${message.notification?.title}/${message.notification?.body} '
      'data=${message.data}',
    );
    final notif = message.notification;
    if (notif == null) {
      // Data-only push in foreground: still try to honor data.url (some FCM
      // payloads omit notification when content-available is set).
      final url = message.data['url'] as String?;
      if (url != null && url.isNotEmpty) {
        _dispatchUrl(url, source: 'fg-data-only');
      }
      return;
    }

    String? imageUrl;
    if (Platform.isAndroid) {
      imageUrl = notif.android?.imageUrl;
    } else {
      imageUrl = notif.apple?.imageUrl;
    }

    AndroidNotificationDetails? androidDetails;
    DarwinNotificationDetails? iosDetails;

    if (imageUrl != null && imageUrl.isNotEmpty) {
      final bytes = await _downloadImage(imageUrl);
      if (bytes != null) {
        if (Platform.isAndroid) {
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
        } else if (Platform.isIOS) {
          try {
            // Save to temp file so iOS UNNotification can attach it.
            final ext = _imageExtFromUrl(imageUrl);
            final tmp = File(
              '${Directory.systemTemp.path}/tf_notif_${DateTime.now().millisecondsSinceEpoch}$ext',
            );
            await tmp.writeAsBytes(bytes);
            iosDetails = DarwinNotificationDetails(
              attachments: [DarwinNotificationAttachment(tmp.path)],
            );
          } catch (e) {
            debugPrint('[PULSE] iOS attachment failed: $e');
          }
        }
      }
    }

    androidDetails ??= const AndroidNotificationDetails(
      pulseChannelId,
      pulseChannelLabel,
      importance: Importance.high,
      priority: Priority.high,
      icon: pulseIconRes,
    );
    iosDetails ??= const DarwinNotificationDetails();

    final payload =
        message.data.isNotEmpty ? jsonEncode(message.data) : null;

    await _tray.show(
      notif.hashCode,
      notif.title,
      notif.body,
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: payload,
    );
  }

  Future<void> _onColdStart(RemoteMessage message) async {
    final url = message.data['url'] as String?;
    debugPrint(
      '[PULSE] cold-start tap data=${message.data} url=${url ?? 'null'}',
    );
    if (url != null && url.isNotEmpty) {
      // Await the stash write so the URL is persisted before bootstrap()
      // returns and EntryGate calls consumeOneShotPush(). Without await,
      // the async write could complete after the read, losing the URL.
      await _cache.stashOneShotPush(url);
    }
  }

  void _onTapInBackground(RemoteMessage message) {
    final url = message.data['url'] as String?;
    debugPrint(
      '[PULSE] background tap data=${message.data} url=${url ?? 'null'}',
    );
    if (url != null && url.isNotEmpty) {
      _dispatchUrl(url, source: 'bg-tap');
    }
  }

  // Routes a push-supplied URL to the live WebView when the BrowserShell is
  // mounted, otherwise stashes it so EntryGate can consume it on next entry.
  // Without the stash fallback, push URLs were silently dropped whenever the
  // user tapped a notification while the app was anywhere outside the browser
  // (loading screen, main menu, or the white arcade flow).
  void _dispatchUrl(String url, {required String source}) {
    final cb = onPushDestination;
    if (cb != null) {
      debugPrint('[PULSE] dispatch url ($source) → live WebView');
      cb(url);
      return;
    }
    debugPrint('[PULSE] dispatch url ($source) → stash for next entry');
    _cache.stashOneShotPush(url);
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

  String _imageExtFromUrl(String url) {
    try {
      final path = Uri.parse(url).path;
      final dot = path.lastIndexOf('.');
      if (dot != -1) {
        final ext = path.substring(dot).toLowerCase();
        if (const ['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext)) {
          return ext;
        }
      }
    } catch (_) {}
    return '.jpg';
  }
}
