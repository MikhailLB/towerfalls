// Reference entry-point for the gray-android-template branch.
//
// This file is intentionally tiny — its only job is to demonstrate how the
// gray boot module plugs into a Flutter app. Drop this file into your host
// project and you can either:
//
//   (a) replace its `runApp` with your own `MaterialApp` and use
//       `gray.buildHome(fallbackHomeBuilder: ...)` for the `home:` slot, OR
//
//   (b) keep this whole file and replace `_DemoHostHome` below with your
//       app's main screen widget.
//
// See `GRAY_PART.md` for the full integration guide.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gray/gray_boot.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Edge-to-edge chrome. Optional — gray flow itself toggles immersive mode
  // inside the WebView; this is only the look of the splash + host home.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  final gray = await GrayBoot.prepare();
  runApp(GrayTemplateApp(gray: gray));
}

class GrayTemplateApp extends StatelessWidget {
  final GrayBoot gray;
  const GrayTemplateApp({super.key, required this.gray});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gray Template',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF06080F),
        useMaterial3: true,
      ),
      home: gray.buildHome(
        fallbackHomeBuilder: (_) => const _DemoHostHome(),
      ),
    );
  }
}

/// Placeholder for the host app's "regular" home screen. The gray flow opens
/// it whenever the gateway decides the user is organic (no destination URL).
class _DemoHostHome extends StatelessWidget {
  const _DemoHostHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF06080F),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.apps_rounded, size: 72, color: Color(0xFFFFC44E)),
                SizedBox(height: 18),
                Text(
                  'Gray template — host home placeholder',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 10),
                Text(
                  'Replace _DemoHostHome with your real screen.\n'
                  'The gray flow lands here when the gateway returns\n'
                  '"no destination" (organic install).',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xAAFFFFFF), fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
