# gray_android_template

Drop-in **gray-flow** Flutter module for Android.

Provides the full attribution / remote gateway / FCM / WebView boot pipeline
in a single `lib/gray/` folder plus a tiny `GrayBoot` facade. Merge into any
host Flutter project and call `GrayBoot.prepare()` + `gray.buildHome(...)`
from `main()`.

**Read [`GRAY_PART.md`](GRAY_PART.md) for the full integration guide,
architecture, and configuration reference.**

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final gray = await GrayBoot.prepare();
  runApp(MaterialApp(
    home: gray.buildHome(
      fallbackHomeBuilder: (_) => const MyExistingHomeScreen(),
    ),
  ));
}
```

When no AppsFlyer/Firebase/gateway keys have been provisioned, `GrayBoot`
short-circuits straight to `fallbackHomeBuilder` — so dropping this module
into a project is a safe no-op until you fill the keys.
