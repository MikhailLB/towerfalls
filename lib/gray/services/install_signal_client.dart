import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:appsflyer_sdk/appsflyer_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../config/gateway_endpoints.dart';
import '../config/runtime_brand.dart';
import 'secure_http.dart';

/// Wraps the AppsFlyer SDK and exposes the conversion / deep-link payloads
/// the gateway client needs to authenticate the install request.
class InstallSignalClient {
  AppsflyerSdk? _sdk;
  Map<String, dynamic>? _conversion;
  Map<String, dynamic>? _deepLink;
  Map<String, dynamic>? _reopen;

  final Completer<Map<String, dynamic>> _conversionGate = Completer();
  final Completer<void> _deepLinkGate = Completer();
  bool _started = false;
  // Cached warmup future so calling `warmup()` multiple times (from main()
  // pre-fire and from EntryGate) returns the SAME in-flight future instead
  // of bumping `_started` and short-circuiting one of them prematurely.
  Future<void>? _warmupFuture;

  bool get started => _started;

  Future<void> _requestAttPrompt() async {
    try {
      // Status read is a fast platform-channel lookup (no UI). Do it FIRST so
      // returning launches (status already authorized/denied) skip the
      // endOfFrame+delay block entirely. Used to add 700ms to every cold
      // start unconditionally.
      final status =
          await AppTrackingTransparency.trackingAuthorizationStatus;
      debugPrint('[TF.ISC] ATT status before prompt=$status');
      if (status != TrackingStatus.notDetermined) return;

      // Only when we're actually going to show the prompt do we have to wait
      // for the app to become active. iOS silently drops
      // requestTrackingAuthorization calls made while the app is inactive
      // (UIApplicationState != active), so we wait for first frame + a small
      // breathing buffer.
      await WidgetsBinding.instance.endOfFrame;
      await Future.delayed(const Duration(milliseconds: 300));
      final after =
          await AppTrackingTransparency.requestTrackingAuthorization();
      debugPrint('[TF.ISC] ATT status after prompt=$after');
    } catch (err) {
      debugPrint('[TF.ISC] ATT skipped: $err');
    }
  }

  Future<void> warmup() {
    return _warmupFuture ??= _doWarmup();
  }

  Future<void> _doWarmup() async {
    if (_started) {
      debugPrint('[TF.ISC] warmup already started — skip');
      return;
    }
    final devKey = RuntimeBrand.installDevKey;
    debugPrint('[TF.ISC] warmup begin, devKeyLen=${devKey.length}');
    if (devKey.isEmpty) {
      _started = true;
      if (!_conversionGate.isCompleted) {
        _conversionGate.complete(<String, dynamic>{});
      }
      if (!_deepLinkGate.isCompleted) {
        _deepLinkGate.complete();
      }
      debugPrint('[TF.ISC] dev key empty — skipping AppsFlyer init');
      return;
    }

    _started = true;
    try {
      if (Platform.isIOS) {
        debugPrint('[TF.ISC] iOS → ATT prompt');
        await _requestAttPrompt();
      }
      final opts = AppsFlyerOptions(
        afDevKey: devKey,
        appId: RuntimeBrand.iosAppId,
        showDebug: kDebugMode,
        // SDK pauses its launch event until ATT decision OR this deadline.
        // 10s used to dominate first-launch timing whenever the user took
        // even a moment to read the prompt. 4s is enough for a deliberate
        // tap; if the user drags it out the SDK proceeds without IDFA which
        // is exactly the same outcome as denying ATT — fail-soft is fine.
        timeToWaitForATTUserAuthorization: 4,
      );
      _sdk = AppsflyerSdk(opts);

      _sdk!.onInstallConversionData(_handleConversion);
      _sdk!.onAppOpenAttribution(_handleReopen);
      _sdk!.onDeepLinking(_handleDeepLink);

      debugPrint('[TF.ISC] AppsflyerSdk.initSdk()');
      await _sdk!.initSdk(
        registerConversionDataCallback: true,
        registerOnAppOpenAttributionCallback: true,
        registerOnDeepLinkingCallback: true,
      );
      debugPrint('[TF.ISC] initSdk OK');
    } catch (err, st) {
      debugPrint('[TF.ISC] warmup error: $err\n$st');
      if (!_conversionGate.isCompleted) {
        _conversionGate.complete(<String, dynamic>{});
      }
      if (!_deepLinkGate.isCompleted) {
        _deepLinkGate.complete();
      }
    }
  }

  Map<String, dynamic> _flatten(dynamic raw) {
    final map = Map<String, dynamic>.from(raw as Map);
    final inner = map['payload'];
    if (inner is Map) {
      return Map<String, dynamic>.from(inner);
    }
    return map;
  }

  void _handleConversion(dynamic raw) async {
    final data = _flatten(raw);
    debugPrint('[TF.ISC] conversion ${jsonEncode(data)}');

    if (data['af_status'] == 'Organic') {
      await Future.delayed(
        Duration(seconds: RuntimeBrand.organicRefetchSeconds),
      );
      final refresh = await _refetchGcd();
      _conversion = refresh ?? data;
    } else {
      _conversion = data;
    }

    if (!_conversionGate.isCompleted) {
      _conversionGate.complete(_conversion);
    }
  }

  void _handleReopen(dynamic raw) {
    _reopen = _flatten(raw);
  }

  void _handleDeepLink(DeepLinkResult result) {
    if (result.deepLink != null) {
      _deepLink = result.deepLink!.clickEvent;
    }
    if (!_deepLinkGate.isCompleted) {
      _deepLinkGate.complete();
    }
  }

  Future<Map<String, dynamic>?> _refetchGcd() async {
    try {
      final id = await deviceIdentifier();
      if (id == null) return null;

      final appId =
          Platform.isIOS ? RuntimeBrand.iosAppId : RuntimeBrand.packageName;
      final url = gcdEndpoint(appId, id);
      if (url.isEmpty) return null;

      final response = await secureHttp.get(
        Uri.parse(url),
        headers: {
          'authorization': 'Bearer ${RuntimeBrand.installDevKey}',
        },
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) return decoded;
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>> awaitConversion({
    Duration timeout = const Duration(seconds: 25),
  }) {
    return _conversionGate.future.timeout(timeout, onTimeout: () {
      debugPrint(
          '[TF.ISC] awaitConversion TIMEOUT after ${timeout.inSeconds}s');
      return <String, dynamic>{};
    });
  }

  Future<void> awaitDeepLink({
    Duration timeout = const Duration(seconds: 5),
  }) {
    return _deepLinkGate.future.timeout(timeout, onTimeout: () {});
  }

  Future<String?> deviceIdentifier() async {
    if (_sdk == null) return null;
    try {
      return await _sdk!.getAppsFlyerUID();
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> composePayload({
    required String locale,
    String? pushToken,
  }) async {
    final payload = <String, dynamic>{};
    if (_conversion != null) payload.addAll(_conversion!);
    if (_deepLink != null) {
      _deepLink!.forEach((k, v) => payload.putIfAbsent(k, () => v));
    }
    if (_reopen != null) {
      _reopen!.forEach((k, v) => payload.putIfAbsent(k, () => v));
    }

    final id = await deviceIdentifier();
    if (id != null && id.isNotEmpty) {
      payload['af_id'] = id;
      if ((payload['sub_id_7'] as String? ?? '').isEmpty) {
        payload['sub_id_7'] = id;
      }
    } else if ((payload['af_id'] as String? ?? '').isEmpty) {
      payload['af_id'] = '';
      payload['sub_id_7'] = payload['sub_id_7'] ?? '';
    }

    if (Platform.isIOS) {
      try {
        // Only read IDFA when the user has explicitly authorized tracking via
        // ATT. Apple privacy review flags any unconditional call to
        // getAdvertisingIdentifier() as a tracking-policy violation, even
        // though iOS itself returns zeros when authorization was denied. By
        // gating on `authorized` we keep the binary clean of any code path
        // that could be interpreted as reading IDFA without consent.
        final status =
            await AppTrackingTransparency.trackingAuthorizationStatus;
        if (status == TrackingStatus.authorized) {
          final idfa =
              await AppTrackingTransparency.getAdvertisingIdentifier();
          if (idfa.isNotEmpty && !idfa.startsWith('00000000-')) {
            payload.putIfAbsent('sub_id_10', () => idfa);
          }
        }
      } catch (_) {}
    }

    payload['bundle_id'] = RuntimeBrand.packageName;
    payload['store_id'] = RuntimeBrand.storeIdentifier;
    payload['os'] = Platform.isAndroid ? 'Android' : 'iOS';
    payload['locale'] = locale;
    if (pushToken != null && pushToken.isNotEmpty) {
      payload['push_token'] = pushToken;
    }
    if (RuntimeBrand.firebaseProjectNumber.isNotEmpty) {
      payload['firebase_project_id'] = RuntimeBrand.firebaseProjectNumber;
    }

    debugPrint('[TF.ISC] payload ${jsonEncode(payload)}');
    return payload;
  }
}
