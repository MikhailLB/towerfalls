import 'dart:io';

import '../utils/byte_unmask.dart';
import 'gateway_endpoints.dart';

/// Per-brand constants that control the gray boot flow. Values that need to
/// stay private (AppsFlyer dev key, Firebase project number) live as
/// obfuscated byte arrays. Until the brand owner ships them the constants
/// resolve to empty strings — see [RuntimeBrand.gateEnabled].

// Android AppsFlyer dev key.
const List<int> _installKeyAndroid = <int>[
  247, 100, 217, 57, 197, 192, 123, 28, 154, 171, 210, 202,
  29, 117, 153, 201, 225, 127, 186, 218, 226, 207,
];

// iOS AppsFlyer dev key.
const List<int> _installKeyIos = <int>[
  161, 76, 215, 48, 165, 206, 71, 41, 171, 176, 238, 210,
  8, 68, 175, 190, 245, 73, 158, 244, 229, 250,
];

// Android Firebase project number — used by App Check / messaging diagnostics.
const List<int> _firebaseProjectAndroid = <int>[
  162, 18, 129, 85, 167, 129, 24, 93, 238, 225, 183, 148,
];

// iOS Firebase project number.
const List<int> _firebaseProjectIos = <int>[
  160, 26, 129, 80, 171, 142, 30, 92, 228, 224, 181, 154,
];

abstract final class RuntimeBrand {
  static const String packageName = 'com.tstudiomgames.towerfalls';
  static const String storeIdentifier = 'com.tstudiomgames.towerfalls';
  static const String displayTitle = 'Tower Falls';
  static const String iosAppId = '6763527518';

  // Three days, expressed in seconds. Used for push opt-in cool downs.
  static const int notifyCooldownSeconds = 60 * 60 * 24 * 3;

  // Delay before re-querying GCD when AppsFlyer reports an Organic install.
  static const int organicRefetchSeconds = 6;

  static String get installDevKey => Platform.isIOS
      ? unmask(_installKeyIos)
      : unmask(_installKeyAndroid);

  static String get firebaseProjectNumber => Platform.isIOS
      ? unmask(_firebaseProjectIos)
      : unmask(_firebaseProjectAndroid);

  /// Debug-only: forces the attribution layer to report Non-organic so the
  /// gray boot flow can be exercised on dev/TestFlight builds without a real
  /// paid-install link. MUST be `false` before shipping to production.
  static const bool debugForceNonOrganic = true;

  static String get configUrl => gateEndpoint();
  static String get chromeBuild => webChromeVersion();
  static String get safariBuild => webSafariVersion();
  static String get privacyUrl => brandPrivacyUrl;
  static String get supportUrl => brandSupportUrl;

  /// `true` when at least one piece of the gray gate has been provisioned.
  /// Lets [main.dart] decide whether to even mount the gray entry gate or
  /// jump straight into the existing Tower Falls game flow.
  static bool get gateEnabled =>
      configUrl.isNotEmpty || installDevKey.isNotEmpty;
}
