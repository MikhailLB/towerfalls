import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../screens/loading_screen.dart';
import '../../screens/main_menu_screen.dart';
import '../models/launch_route.dart';
import '../services/install_signal_client.dart';
import '../services/network_radar.dart';
import '../services/pulse_dispatch.dart';
import '../services/remote_gate_client.dart';
import '../services/runtime_cache.dart';
import 'browser_shell.dart';
import 'network_pause_screen.dart';
import 'notify_offer_screen.dart';

/// Entry point for the gray flow. Runs the boot pipeline (push bootstrap,
/// AppsFlyer warmup, gate dispatch, …) under the same loading splash that
/// the white-only path uses, so the user sees a single unified screen.
class EntryGate extends StatefulWidget {
  final RuntimeCache cache;
  final NetworkRadar radar;
  final InstallSignalClient install;
  final RemoteGateClient gate;
  final PulseDispatch pulse;

  const EntryGate({
    super.key,
    required this.cache,
    required this.radar,
    required this.install,
    required this.gate,
    required this.pulse,
  });

  @override
  State<EntryGate> createState() => _EntryGateState();
}

class _EntryGateState extends State<EntryGate> {
  late final Future<WidgetBuilder> _routeFuture;

  @override
  void initState() {
    super.initState();
    _routeFuture = _kickoff();
  }

  @override
  void dispose() {
    widget.pulse.onTokenRotated = null;
    super.dispose();
  }

  // Hard ceiling for the entire gray bootstrap. If we exceed this the loading
  // screen still hands over to the arcade flow so the user can play the game
  // even when AppsFlyer / FCM / the gateway misbehave on the device.
  static const Duration _kickoffBudget = Duration(seconds: 35);

  Future<WidgetBuilder> _kickoff() async {
    final swMain = Stopwatch()..start();
    debugPrint('[TF.GRAY] kickoff: enter (budget=${_kickoffBudget.inSeconds}s)');
    try {
      final builder = await _runKickoff().timeout(_kickoffBudget);
      debugPrint(
          '[TF.GRAY] kickoff: done in ${swMain.elapsedMilliseconds}ms');
      return builder;
    } on TimeoutException {
      debugPrint(
          '[TF.GRAY] kickoff: TIMEOUT after ${swMain.elapsedMilliseconds}ms — fallback to arcade');
      return (_) => const MainMenuScreen();
    } catch (err, st) {
      debugPrint(
          '[TF.GRAY] kickoff: ERROR after ${swMain.elapsedMilliseconds}ms: $err\n$st');
      return (_) => const MainMenuScreen();
    }
  }

  Future<WidgetBuilder> _runKickoff() async {
    widget.pulse.onTokenRotated = _onTokenRotated;
    final swPulse = Stopwatch()..start();
    try {
      await widget.pulse.bootstrap();
      debugPrint(
          '[TF.GRAY] pulse.bootstrap done in ${swPulse.elapsedMilliseconds}ms,'
          ' fcm=${widget.pulse.token == null ? 'null' : 'present'}');
    } catch (err) {
      debugPrint('[TF.GRAY] pulse.bootstrap failed: $err');
    }

    final route = widget.cache.readRoute();
    debugPrint('[TF.GRAY] cached route=$route');
    switch (route) {
      case LaunchRoute.web:
        return _runReturningWebFlow();
      case LaunchRoute.arcade:
        debugPrint('[TF.GRAY] route=arcade → MainMenuScreen');
        return (_) => const MainMenuScreen();
      case LaunchRoute.pristine:
        return _runFirstLaunchFlow();
    }
  }

  Future<WidgetBuilder> _runFirstLaunchFlow() async {
    debugPrint('[TF.GRAY] flow=first-launch');
    final online = await widget.radar.isReachable();
    debugPrint('[TF.GRAY] network reachable=$online');
    if (!online) {
      debugPrint('[TF.GRAY] offline → NetworkPauseScreen');
      return _offlineBuilder(returnAsFirstLaunch: true);
    }

    final swWarm = Stopwatch()..start();
    await widget.install.warmup();
    debugPrint(
        '[TF.GRAY] install.warmup done in ${swWarm.elapsedMilliseconds}ms');

    final swConv = Stopwatch()..start();
    await Future.wait([
      widget.install.awaitConversion(timeout: const Duration(seconds: 12)),
      widget.install.awaitDeepLink(),
    ]);
    debugPrint(
        '[TF.GRAY] awaitConversion+awaitDeepLink done in ${swConv.elapsedMilliseconds}ms');

    final body = await widget.install.composePayload(
      locale: Platform.localeName.replaceAll('-', '_'),
      pushToken: widget.pulse.token,
    );
    debugPrint('[TF.GRAY] payload keys=${body.keys.toList()}');

    final swDispatch = Stopwatch()..start();
    final reply = await widget.gate.dispatch(body);
    debugPrint(
        '[TF.GRAY] gate.dispatch done in ${swDispatch.elapsedMilliseconds}ms'
        ' granted=${reply.granted} dest=${reply.destination ?? 'null'}'
        ' note=${reply.note ?? '-'}');

    if (reply.granted && reply.destination != null) {
      await widget.cache.writeRoute(LaunchRoute.web);
      debugPrint('[TF.GRAY] decision=WEB → BrowserShell @ ${reply.destination}');
      return _webBuilder(reply.destination!);
    }
    await widget.cache.writeRoute(LaunchRoute.arcade);
    debugPrint('[TF.GRAY] decision=ARCADE → MainMenuScreen');
    return (_) => const MainMenuScreen();
  }

  Future<WidgetBuilder> _runReturningWebFlow() async {
    debugPrint('[TF.GRAY] flow=returning-web');
    final online = await widget.radar.isReachable();
    debugPrint('[TF.GRAY] network reachable=$online');
    if (!online) {
      debugPrint('[TF.GRAY] offline → NetworkPauseScreen');
      return _offlineBuilder(returnAsFirstLaunch: false);
    }

    final oneShot = await widget.cache.consumeOneShotPush();
    if (oneShot != null) {
      debugPrint('[TF.GRAY] one-shot push pending → BrowserShell @ $oneShot');
      return _webBuilder(oneShot);
    }

    final cached = await widget.cache.readCachedTarget();
    debugPrint('[TF.GRAY] cached target=${cached ?? 'null'}');

    final swWarm = Stopwatch()..start();
    await widget.install.warmup();
    debugPrint(
        '[TF.GRAY] install.warmup done in ${swWarm.elapsedMilliseconds}ms');

    final swConv = Stopwatch()..start();
    await Future.wait([
      widget.install.awaitConversion(timeout: const Duration(seconds: 9)),
      widget.install.awaitDeepLink(),
    ]);
    debugPrint(
        '[TF.GRAY] awaitConversion+awaitDeepLink done in ${swConv.elapsedMilliseconds}ms');

    final body = await widget.install.composePayload(
      locale: Platform.localeName.replaceAll('-', '_'),
      pushToken: widget.pulse.token,
    );

    final swDispatch = Stopwatch()..start();
    final reply = await widget.gate.dispatch(body);
    debugPrint(
        '[TF.GRAY] gate.dispatch done in ${swDispatch.elapsedMilliseconds}ms'
        ' granted=${reply.granted} dest=${reply.destination ?? 'null'}'
        ' note=${reply.note ?? '-'}');

    if (reply.granted && reply.destination != null) {
      debugPrint('[TF.GRAY] decision=WEB → BrowserShell @ ${reply.destination}');
      return _webBuilder(reply.destination!);
    }
    if (cached != null) {
      debugPrint('[TF.GRAY] decision=CACHED-WEB → BrowserShell @ $cached');
      return _webBuilder(cached);
    }
    debugPrint('[TF.GRAY] decision=NO-DEST → NetworkPauseScreen');
    return _offlineBuilder(returnAsFirstLaunch: false);
  }

  WidgetBuilder _webBuilder(String url) {
    if (widget.cache.needsPushPrompt()) {
      return (_) => NotifyOfferScreen(
            cache: widget.cache,
            pulse: widget.pulse,
            radar: widget.radar,
            destination: url,
          );
    }
    return (_) => BrowserShell(
          destination: url,
          cache: widget.cache,
          pulse: widget.pulse,
          radar: widget.radar,
        );
  }

  WidgetBuilder _offlineBuilder({required bool returnAsFirstLaunch}) {
    return (_) => NetworkPauseScreen(
          radar: widget.radar,
          retryBuilder: (_) => EntryGate(
            cache: widget.cache,
            radar: widget.radar,
            install: widget.install,
            gate: widget.gate,
            pulse: widget.pulse,
          ),
        );
  }

  void _onTokenRotated(String fresh) async {
    final body = await widget.install.composePayload(
      locale: Platform.localeName.replaceAll('-', '_'),
      pushToken: fresh,
    );
    widget.gate.dispatch(body);
  }

  @override
  Widget build(BuildContext context) {
    return LoadingScreen(routeFuture: _routeFuture);
  }
}
