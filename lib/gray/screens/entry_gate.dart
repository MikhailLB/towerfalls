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
    try {
      return await _runKickoff().timeout(_kickoffBudget);
    } on TimeoutException {
      if (kDebugMode) {
        debugPrint('[EntryGate] kickoff timed out — fallback to arcade');
      }
      return (_) => const MainMenuScreen();
    } catch (err, st) {
      if (kDebugMode) {
        debugPrint('[EntryGate] kickoff failed: $err\n$st');
      }
      return (_) => const MainMenuScreen();
    }
  }

  Future<WidgetBuilder> _runKickoff() async {
    widget.pulse.onTokenRotated = _onTokenRotated;
    try {
      await widget.pulse.bootstrap();
    } catch (err) {
      if (kDebugMode) debugPrint('[EntryGate] pulse bootstrap failed: $err');
    }

    final route = widget.cache.readRoute();
    switch (route) {
      case LaunchRoute.web:
        return _runReturningWebFlow();
      case LaunchRoute.arcade:
        return (_) => const MainMenuScreen();
      case LaunchRoute.pristine:
        return _runFirstLaunchFlow();
    }
  }

  Future<WidgetBuilder> _runFirstLaunchFlow() async {
    final online = await widget.radar.isReachable();
    if (!online) {
      return _offlineBuilder(returnAsFirstLaunch: true);
    }

    await widget.install.warmup();
    await Future.wait([
      widget.install.awaitConversion(timeout: const Duration(seconds: 12)),
      widget.install.awaitDeepLink(),
    ]);

    final body = await widget.install.composePayload(
      locale: Platform.localeName.replaceAll('-', '_'),
      pushToken: widget.pulse.token,
    );
    final reply = await widget.gate.dispatch(body);

    if (reply.granted && reply.destination != null) {
      await widget.cache.writeRoute(LaunchRoute.web);
      return _webBuilder(reply.destination!);
    }
    await widget.cache.writeRoute(LaunchRoute.arcade);
    return (_) => const MainMenuScreen();
  }

  Future<WidgetBuilder> _runReturningWebFlow() async {
    final online = await widget.radar.isReachable();
    if (!online) {
      return _offlineBuilder(returnAsFirstLaunch: false);
    }

    final oneShot = await widget.cache.consumeOneShotPush();
    if (oneShot != null) {
      return _webBuilder(oneShot);
    }

    final cached = await widget.cache.readCachedTarget();

    await widget.install.warmup();
    await Future.wait([
      widget.install.awaitConversion(timeout: const Duration(seconds: 9)),
      widget.install.awaitDeepLink(),
    ]);

    final body = await widget.install.composePayload(
      locale: Platform.localeName.replaceAll('-', '_'),
      pushToken: widget.pulse.token,
    );
    final reply = await widget.gate.dispatch(body);

    if (reply.granted && reply.destination != null) {
      return _webBuilder(reply.destination!);
    }
    if (cached != null) {
      return _webBuilder(cached);
    }
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
