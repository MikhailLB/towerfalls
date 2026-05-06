import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'gray/config/runtime_brand.dart';
import 'gray/screens/entry_gate.dart';
import 'gray/services/install_signal_client.dart';
import 'gray/services/network_radar.dart';
import 'gray/services/pulse_dispatch.dart';
import 'gray/services/remote_gate_client.dart';
import 'gray/services/runtime_cache.dart';
import 'gray/services/secure_http.dart';
import 'screens/loading_screen.dart';

Future<void> _bootFirebase() async {
  try {
    await Firebase.initializeApp();
  } catch (err) {
    if (kDebugMode) debugPrint('[BOOT] Firebase skipped: $err');
    return;
  }
  try {
    await FirebaseAppCheck.instance.activate(
      androidProvider: kDebugMode
          ? AndroidProvider.debug
          : AndroidProvider.playIntegrity,
      appleProvider: kDebugMode
          ? AppleProvider.debug
          : AppleProvider.appAttestWithDeviceCheckFallback,
    );
  } catch (err) {
    if (kDebugMode) debugPrint('[BOOT] AppCheck skipped: $err');
  }
}

Future<void> _applyChrome() async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
}

Future<void> main() async {
  final swMain = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();

  // Run independent initialization in parallel. Firebase init dominates this
  // phase (~700-1500ms), but secureHttp.warmup (DeviceInfo lookup) and
  // cache.bootstrap (SharedPreferences open) used to be awaited sequentially
  // afterwards even though they don't depend on Firebase at all. Running
  // them concurrently saves ~250-400ms before runApp.
  unawaited(_applyChrome());
  final firebaseFuture = _bootFirebase();
  final httpFuture = secureHttp.warmup();
  final cache = RuntimeCache();
  final cacheFuture = cache.bootstrap().catchError((err) {
    debugPrint('[TF.GRAY] RuntimeCache failed: $err');
  });

  await firebaseFuture;
  debugPrint('[TF.GRAY] firebase ready in ${swMain.elapsedMilliseconds}ms');
  await Future.wait([httpFuture, cacheFuture]);
  debugPrint('[TF.GRAY] http+cache ready in ${swMain.elapsedMilliseconds}ms');

  final radar = NetworkRadar();
  final install = InstallSignalClient();
  final gate = RemoteGateClient(cache);
  final pulse = PulseDispatch(cache);

  // PRE-FIRE pulse.bootstrap so its expensive network work (APNs token poll,
  // FCM token fetch, getInitialMessage round-trip — used to add 4-7s to
  // first paint when started lazily inside EntryGate) overlaps with the
  // first frame, splash video init, and EntryGate.initState. The future is
  // cached inside PulseDispatch so EntryGate's `await widget.pulse.bootstrap()`
  // returns the same in-flight handle instead of starting a second copy.
  unawaited(pulse.bootstrap().catchError((err) {
    debugPrint('[TF.GRAY] pulse pre-fire failed: $err');
  }));

  debugPrint('[TF.GRAY] runtime brand:'
      ' gateEnabled=${RuntimeBrand.gateEnabled}'
      ' configUrl="${RuntimeBrand.configUrl}"'
      ' devKeyLen=${RuntimeBrand.installDevKey.length}'
      ' fbProj=${RuntimeBrand.firebaseProjectNumber}'
      ' iosAppId=${RuntimeBrand.iosAppId}'
      ' bundle=${RuntimeBrand.packageName}'
      ' bootMs=${swMain.elapsedMilliseconds}');

  runApp(TowerFallsApp(
    cache: cache,
    radar: radar,
    install: install,
    gate: gate,
    pulse: pulse,
  ));
}

class TowerFallsApp extends StatelessWidget {
  final RuntimeCache cache;
  final NetworkRadar radar;
  final InstallSignalClient install;
  final RemoteGateClient gate;
  final PulseDispatch pulse;

  const TowerFallsApp({
    super.key,
    required this.cache,
    required this.radar,
    required this.install,
    required this.gate,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    final Widget home = RuntimeBrand.gateEnabled
        ? EntryGate(
            cache: cache,
            radar: radar,
            install: install,
            gate: gate,
            pulse: pulse,
          )
        : const LoadingScreen();

    return MaterialApp(
      title: 'Tower Falls',
      debugShowCheckedModeBanner: false,
      theme: buildTowerFallsTheme(),
      home: home,
    );
  }
}
