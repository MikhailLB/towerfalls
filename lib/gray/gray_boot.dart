import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'config/runtime_brand.dart';
import 'screens/entry_gate.dart';
import 'services/install_signal_client.dart';
import 'services/network_radar.dart';
import 'services/pulse_dispatch.dart';
import 'services/remote_gate_client.dart';
import 'services/runtime_cache.dart';
import 'services/secure_http.dart';

/// One-stop wiring for the gray boot flow.
///
/// Usage (in your host app's `main`):
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   final gray = await GrayBoot.prepare();
///   runApp(MaterialApp(
///     home: gray.buildHome(
///       fallbackHomeBuilder: (_) => const MyOriginalHomeScreen(),
///     ),
///   ));
/// }
/// ```
///
/// All the wiring (Firebase init, AppCheck, AppsFlyer warmup container,
/// `RuntimeCache`, push dispatcher, gateway client) is constructed once and
/// re-used. [buildHome] returns either the gray [EntryGate] when the brand
/// has been provisioned ([RuntimeBrand.gateEnabled] = true) or the host's
/// fallback home directly when the brand is empty — so dropping this module
/// into a project with no AppsFlyer / Firebase keys is a safe no-op.
class GrayBoot {
  final RuntimeCache cache;
  final NetworkRadar radar;
  final InstallSignalClient install;
  final RemoteGateClient gate;
  final PulseDispatch pulse;
  final bool firebaseReady;

  GrayBoot._({
    required this.cache,
    required this.radar,
    required this.install,
    required this.gate,
    required this.pulse,
    required this.firebaseReady,
  });

  /// Initialises Firebase + AppCheck, warms up the HTTP client and opens the
  /// persistence layer. Safe to call multiple times — Firebase guards against
  /// `[core/duplicate-app]` internally on most versions.
  static Future<GrayBoot> prepare() async {
    final firebaseReady = await _bootFirebase();

    await secureHttp.warmup();

    final cache = RuntimeCache();
    try {
      await cache.bootstrap();
    } catch (err) {
      if (kDebugMode) debugPrint('[GrayBoot] RuntimeCache failed: $err');
    }

    final radar = NetworkRadar();
    final install = InstallSignalClient();
    final gate = RemoteGateClient(cache);
    final pulse = PulseDispatch(cache);

    return GrayBoot._(
      cache: cache,
      radar: radar,
      install: install,
      gate: gate,
      pulse: pulse,
      firebaseReady: firebaseReady,
    );
  }

  /// Returns the widget the host app should mount as its `home`.
  ///
  ///   • If the brand has been provisioned, this is the gray [EntryGate].
  ///   • If the brand is empty (no AppsFlyer dev key AND no gateway URL),
  ///     this short-circuits straight to [fallbackHomeBuilder] — no boot
  ///     pipeline, no splash, no gateway requests.
  ///
  /// Pass [splashBuilder] to replace the default splash. See
  /// [GraySplashBuilder] / [EntryGate] for the contract.
  Widget buildHome({
    required WidgetBuilder fallbackHomeBuilder,
    GraySplashBuilder? splashBuilder,
  }) {
    if (!RuntimeBrand.gateEnabled) {
      return Builder(builder: fallbackHomeBuilder);
    }
    return EntryGate(
      cache: cache,
      radar: radar,
      install: install,
      gate: gate,
      pulse: pulse,
      fallbackHomeBuilder: fallbackHomeBuilder,
      splashBuilder: splashBuilder,
    );
  }

  static Future<bool> _bootFirebase() async {
    try {
      await Firebase.initializeApp();
    } catch (err) {
      if (kDebugMode) debugPrint('[GrayBoot] Firebase skipped: $err');
      return false;
    }
    try {
      await FirebaseAppCheck.instance.activate(
        androidProvider: kDebugMode
            ? AndroidProvider.debug
            : AndroidProvider.playIntegrity,
      );
    } catch (err) {
      if (kDebugMode) debugPrint('[GrayBoot] AppCheck skipped: $err');
    }
    return true;
  }
}
