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
    debugPrint('[TF.RGC] dispatch → endpoint="$endpoint"');
    if (endpoint.isEmpty) {
      debugPrint('[TF.RGC] gateway endpoint missing — declined');
      return GateResponse.declined('endpoint_missing');
    }

    try {
      final uri = Uri.parse(endpoint);
      debugPrint('[TF.RGC] POST $uri body=${jsonEncode(body)}');
      final response = await secureHttp
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8));

      debugPrint('[TF.RGC] HTTP ${response.statusCode}'
          ' contentLen=${response.contentLength ?? response.body.length}');
      final preview = response.body.length > 800
          ? '${response.body.substring(0, 800)}…'
          : response.body;
      debugPrint('[TF.RGC] body=$preview');

      if (response.statusCode != 200) {
        return GateResponse.declined('http_${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        debugPrint('[TF.RGC] body is not a JSON object — declined');
        return GateResponse.declined('bad_json');
      }

      final reply = GateResponse.fromMap(decoded);
      debugPrint('[TF.RGC] parsed reply granted=${reply.granted}'
          ' dest=${reply.destination ?? 'null'}'
          ' note=${reply.note ?? '-'}'
          ' expires=${reply.expiresAtEpoch ?? '-'}');
      if (reply.granted && reply.destination != null) {
        await _cache.writeCachedTarget(reply.destination!);
        final ttl = reply.expiresAtEpoch;
        if (ttl != null) {
          await _cache.writeCachedTtl(ttl);
        }
      }
      return reply;
    } catch (err, st) {
      debugPrint('[TF.RGC] dispatch error: $err\n$st');
      return GateResponse.declined(err.toString());
    }
  }
}
