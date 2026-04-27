import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appsflyer_sdk/appsflyer_sdk.dart';
import 'package:flutter/foundation.dart';

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

  bool get started => _started;

  Future<void> warmup() async {
    if (_started) return;
    final devKey = RuntimeBrand.installDevKey;
    if (devKey.isEmpty) {
      _started = true;
      if (!_conversionGate.isCompleted) {
        _conversionGate.complete(<String, dynamic>{});
      }
      if (!_deepLinkGate.isCompleted) {
        _deepLinkGate.complete();
      }
      if (kDebugMode) {
        debugPrint('[ISC] dev key empty — skipping AppsFlyer init');
      }
      return;
    }

    _started = true;
    try {
      final opts = AppsFlyerOptions(
        afDevKey: devKey,
        appId: RuntimeBrand.iosAppId,
        showDebug: false,
        timeToWaitForATTUserAuthorization: 10,
      );
      _sdk = AppsflyerSdk(opts);

      _sdk!.onInstallConversionData(_handleConversion);
      _sdk!.onAppOpenAttribution(_handleReopen);
      _sdk!.onDeepLinking(_handleDeepLink);

      await _sdk!.initSdk(
        registerConversionDataCallback: true,
        registerOnAppOpenAttributionCallback: true,
        registerOnDeepLinkingCallback: true,
      );
    } catch (err, st) {
      if (kDebugMode) {
        debugPrint('[ISC] warmup error: $err');
        debugPrint('$st');
      }
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
    if (kDebugMode) {
      debugPrint('[ISC] conversion ${jsonEncode(data)}');
    }

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
    return _conversionGate.future
        .timeout(timeout, onTimeout: () => <String, dynamic>{});
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
    } else if ((payload['af_id'] as String? ?? '').isEmpty) {
      payload['af_id'] = '';
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

    if (kDebugMode) {
      debugPrint('[ISC] payload ${jsonEncode(payload)}');
    }
    return payload;
  }
}
