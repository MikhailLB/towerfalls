/// Persisted decision about how the app should boot on subsequent runs.
///
/// `web` opens the WebView, `arcade` jumps directly into the Tower Falls
/// game, `pristine` means the gateway has not answered yet.
enum LaunchRoute {
  web,
  arcade,
  pristine;

  String storageId() {
    switch (this) {
      case LaunchRoute.web:
        return 'web';
      case LaunchRoute.arcade:
        return 'arcade';
      case LaunchRoute.pristine:
        return 'pristine';
    }
  }

  static LaunchRoute decode(String? raw) {
    switch (raw) {
      case 'web':
      case 'browser':
        return LaunchRoute.web;
      case 'arcade':
      case 'game':
        return LaunchRoute.arcade;
      default:
        return LaunchRoute.pristine;
    }
  }
}
