import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;

import '../config/runtime_brand.dart';

String _composeAndroidUa({
  required int sdk,
  required String brand,
  required String model,
  required String build,
}) {
  final chrome = RuntimeBrand.chromeBuild;
  return 'Mozilla/5.0 (Linux; Android $sdk; $brand $model Build/$build) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/$chrome Mobile Safari/537.36';
}

String _composeIosUa(String systemVersion) {
  final safari = RuntimeBrand.safariBuild;
  final dotless = systemVersion.replaceAll('.', '_');
  return 'Mozilla/5.0 (iPhone; CPU iPhone OS $dotless like Mac OS X) '
      'AppleWebKit/$safari (KHTML, like Gecko) '
      'Version/$systemVersion Mobile/15E148 Safari/$safari';
}

String _stockUa() {
  if (Platform.isAndroid) {
    return _composeAndroidUa(
      sdk: 14,
      brand: 'Samsung',
      model: 'SM-S921B',
      build: 'UP1A.231005.007',
    );
  }
  return _composeIosUa('17.4');
}

/// HTTP client that injects a believable mobile-browser User-Agent on every
/// outbound request. Produces a different UA from the white build so the
/// server fingerprint stays distinct.
class SecureHttp extends http.BaseClient {
  final http.Client _delegate = http.Client();
  String _userAgent = '';

  Future<void> warmup() async {
    try {
      final probe = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await probe.androidInfo;
        final tag = info.display.isNotEmpty ? info.display : info.id;
        _userAgent = _composeAndroidUa(
          sdk: info.version.sdkInt,
          brand: info.brand,
          model: info.model,
          build: tag,
        );
      } else if (Platform.isIOS) {
        final info = await probe.iosInfo;
        _userAgent = _composeIosUa(info.systemVersion);
      } else {
        _userAgent = _stockUa();
      }
    } catch (_) {
      _userAgent = _stockUa();
    }
  }

  String get userAgent => _userAgent.isNotEmpty ? _userAgent : _stockUa();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final headers = request.headers;
    if (!headers.containsKey('User-Agent') &&
        !headers.containsKey('user-agent')) {
      headers['User-Agent'] = userAgent;
    }
    return _delegate.send(request);
  }

  @override
  void close() => _delegate.close();
}

final SecureHttp secureHttp = SecureHttp();
