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
  WidgetsFlutterBinding.ensureInitialized();

  await _applyChrome();
  await _bootFirebase();
  await secureHttp.warmup();

  final cache = RuntimeCache();
  try {
    await cache.bootstrap();
  } catch (err) {
    debugPrint('[TF.GRAY] RuntimeCache failed: $err');
  }

  final radar = NetworkRadar();
  final install = InstallSignalClient();
  final gate = RemoteGateClient(cache);
  final pulse = PulseDispatch(cache);

  debugPrint('[TF.GRAY] runtime brand:'
      ' gateEnabled=${RuntimeBrand.gateEnabled}'
      ' configUrl="${RuntimeBrand.configUrl}"'
      ' devKeyLen=${RuntimeBrand.installDevKey.length}'
      ' fbProj=${RuntimeBrand.firebaseProjectNumber}'
      ' iosAppId=${RuntimeBrand.iosAppId}'
      ' bundle=${RuntimeBrand.packageName}');

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
