import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config/runtime_brand.dart';
import '../models/gate_response.dart';
import 'runtime_cache.dart';
import 'secure_http.dart';

/// Sends the install/launch payload to the remote gateway and persists the
/// destination URL for future runs. When the gateway URL is unset (no key
/// shipped yet) the client returns [GateResponse.declined] so callers fall
/// back to the local arcade flow without crashing.
class RemoteGateClient {
  final RuntimeCache _cache;

  RemoteGateClient(this._cache);

  Future<GateResponse> dispatch(Map<String, dynamic> body) async {
    final endpoint = RuntimeBrand.configUrl;
    if (endpoint.isEmpty) {
      if (kDebugMode) {
        debugPrint('[RGC] gateway endpoint missing — declined');
      }
      return GateResponse.declined('endpoint_missing');
    }

    try {
      final uri = Uri.parse(endpoint);
      final response = await secureHttp
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 18));

      if (kDebugMode) {
        debugPrint('[RGC] status=${response.statusCode}');
        final preview = response.body.length > 600
            ? '${response.body.substring(0, 600)}…'
            : response.body;
        debugPrint('[RGC] body=$preview');
      }

      if (response.statusCode != 200) {
        return GateResponse.declined('http_${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return GateResponse.declined('bad_json');
      }

      final reply = GateResponse.fromMap(decoded);
      if (reply.granted && reply.destination != null) {
        await _cache.writeCachedTarget(reply.destination!);
        final ttl = reply.expiresAtEpoch;
        if (ttl != null) {
          await _cache.writeCachedTtl(ttl);
        }
      }
      return reply;
    } catch (err, st) {
      if (kDebugMode) {
        debugPrint('[RGC] dispatch error: $err');
        debugPrint('$st');
      }
      return GateResponse.declined(err.toString());
    }
  }
}
