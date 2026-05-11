/// Optional asset overrides for the gray flow.
///
/// The gray module ships with no bundled artwork — every screen falls back to
/// a Material/gradient placeholder when the corresponding entry below is
/// `null`. To brand the flow, the host app should:
///
/// 1. Add its own assets to `pubspec.yaml` (under `flutter.assets`).
/// 2. Call [GrayAssets.configure] EARLY in `main()`, before `runApp`.
///
/// All fields are optional and independent — provide only the assets you
/// have. Missing entries simply leave the matching screen in its default
/// look. None of the fields are validated; passing an invalid asset path
/// will surface as an Image.asset error at render time but will not crash
/// the boot flow.
abstract final class GrayAssets {
  static String? splashVideoPortrait;
  static String? splashVideoLandscape;
  static String? splashBackground;

  static String? notifyOfferVideoPortrait;
  static String? notifyOfferVideoLandscape;
  static String? notifyOfferBackground;

  static String? networkPauseBackgroundPortrait;
  static String? networkPauseBackgroundLandscape;
  static String? networkPauseRetryButton;

  /// Bulk setter used by the host app from its `main()`.
  static void configure({
    String? splashVideoPortrait,
    String? splashVideoLandscape,
    String? splashBackground,
    String? notifyOfferVideoPortrait,
    String? notifyOfferVideoLandscape,
    String? notifyOfferBackground,
    String? networkPauseBackgroundPortrait,
    String? networkPauseBackgroundLandscape,
    String? networkPauseRetryButton,
  }) {
    GrayAssets.splashVideoPortrait = splashVideoPortrait;
    GrayAssets.splashVideoLandscape = splashVideoLandscape;
    GrayAssets.splashBackground = splashBackground;
    GrayAssets.notifyOfferVideoPortrait = notifyOfferVideoPortrait;
    GrayAssets.notifyOfferVideoLandscape = notifyOfferVideoLandscape;
    GrayAssets.notifyOfferBackground = notifyOfferBackground;
    GrayAssets.networkPauseBackgroundPortrait =
        networkPauseBackgroundPortrait;
    GrayAssets.networkPauseBackgroundLandscape =
        networkPauseBackgroundLandscape;
    GrayAssets.networkPauseRetryButton = networkPauseRetryButton;
  }
}
