import '../utils/byte_unmask.dart';

/// Gateway endpoint and browser-fingerprint helpers for the gray flow.
///
/// Real values are intentionally omitted until the brand owner ships the
/// AppsFlyer dev key and the config endpoint. Until then [gateEndpoint] and
/// [gcdEndpoint] return empty strings, which makes [RemoteGateClient] short
/// circuit to the offline arcade fallback path.

// Server gate URL used for the launch dispatch POST.
const List<int> _gateUrlMask = <int>[
  252, 94, 199, 17, 225, 141, 2, 64, 169, 188, 240, 199, 35, 113, 168, 145,
  193, 65, 156, 158, 236, 247, 212, 184, 22, 134, 180, 218, 212, 65, 207,
  228, 205, 198,
];

// AppsFlyer GCD endpoint used as a backup when the SDK callback is missed.
// Format will be: "<host>?app_id=...&device_id=...".
const List<int> _gcdHostMask = <int>[];

String gateEndpoint() => unmask(_gateUrlMask);

String gcdEndpoint(String appId, String deviceId) {
  final host = unmask(_gcdHostMask);
  if (host.isEmpty) return '';
  final sep = host.contains('?') ? '&' : '?';
  return '$host${sep}app_id=$appId&device_id=$deviceId';
}

/// Chrome major version reported in the WebView/HTTP user agent. Picked to
/// look like a fairly recent stock browser without matching GravityRush.
String webChromeVersion() => '127.0.6533.103';

/// Safari WebKit build number for the iOS user agent variant.
String webSafariVersion() => '605.1.15';

const String brandPrivacyUrl = 'https://towerrfalls.com/privacy-policy.html';
const String brandSupportUrl = 'https://towerrfalls.com/support.html';
