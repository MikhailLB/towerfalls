import 'dart:io';

import '../utils/byte_unmask.dart';
import 'gateway_endpoints.dart';

/// Per-brand constants that control the gray boot flow.
///
/// Values that need to stay private (AppsFlyer dev key, Firebase project
/// number) are stored as obfuscated byte arrays — use
/// `dart run tool/encode_keys.dart` to generate them.
///
/// Until the brand owner ships the real keys, the arrays are empty and
/// [gateEnabled] returns `false`. In that state [GrayBoot.buildHome]
/// short-circuits straight to the host's `fallbackHomeBuilder`, so the app
/// stays fully functional even before the gray flow has been provisioned.

// Android AppsFlyer dev key (mask with `dart run tool/encode_keys.dart`).
const List<int> _installKeyAndroid = <int>[];

// iOS AppsFlyer dev key. Kept here for cross-platform parity even though
// the template branch builds Android only — when the gray module is
// merged into a multi-platform project the iOS key is used automatically.
const List<int> _installKeyIos = <int>[];

// Android Firebase project number — used by App Check / messaging
// diagnostics. Mask with the same tool.
const List<int> _firebaseProjectAndroid = <int>[];

// iOS Firebase project number.
const List<int> _firebaseProjectIos = <int>[];

abstract final class RuntimeBrand {
  /// Android applicationId / iOS bundle ID. Used in the gateway payload
  /// (`bundle_id`, `store_id`) so the server can route per-brand offers.
  static const String packageName = 'com.example.gray_template';

  /// Store-side identifier (Android package or App Store numeric ID).
  /// Defaults to the same value as [packageName] on Android.
  static const String storeIdentifier = 'com.example.gray_template';

  /// Display name shown in any user-facing copy the gray flow renders. Pure
  /// metadata — does NOT affect the launcher icon or the home-screen label
  /// (those are configured in `AndroidManifest.xml` / `Info.plist`).
  static const String displayTitle = 'Gray Template';

  /// App Store numeric ID — only used on iOS for the AppsFlyer
  /// `AppsFlyerOptions.appId`. Leave as-is for Android-only builds.
  static const String iosAppId = '0000000000';

  /// Three days, expressed in seconds. After the user has tapped "Skip" on
  /// the in-app push opt-in screen we keep it hidden for this long before
  /// offering again.
  static const int notifyCooldownSeconds = 60 * 60 * 24 * 3;

  /// Delay before re-querying AppsFlyer GCD when the SDK reports an Organic
  /// install. Some attribution paths only become Non-organic after the
  /// click is matched on the server side, so a quick refetch picks them up.
  static const int organicRefetchSeconds = 6;

  static String get installDevKey => Platform.isIOS
      ? unmask(_installKeyIos)
      : unmask(_installKeyAndroid);

  static String get firebaseProjectNumber => Platform.isIOS
      ? unmask(_firebaseProjectIos)
      : unmask(_firebaseProjectAndroid);

  static String get configUrl => gateEndpoint();
  static String get chromeBuild => webChromeVersion();
  static String get safariBuild => webSafariVersion();
  static String get privacyUrl => brandPrivacyUrl;
  static String get supportUrl => brandSupportUrl;

  /// `true` when at least one piece of the gray gate has been provisioned.
  /// [GrayBoot.buildHome] consults this to decide whether to mount the gray
  /// entry gate at all — when it's `false` (template ships empty) the host
  /// app's `fallbackHomeBuilder` is rendered directly.
  static bool get gateEnabled =>
      configUrl.isNotEmpty || installDevKey.isNotEmpty;
}
