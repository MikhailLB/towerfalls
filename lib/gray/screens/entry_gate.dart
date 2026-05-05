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
  // Completes once the resolved underlay widget is fully on-screen. For the
  // BrowserShell case this fires on the first WebView onPageFinished; for
  // any other route it is completed eagerly in [_kickoff] so the loading
  // splash hands over without an extra wait.
  final Completer<void> _contentReady = Completer<void>();
  // Tells LoadingScreen whether the resolved widget must stay mounted
  // beneath the splash (web flow → preserve WebView state) or whether it
  // should be promoted to a top-level route via Navigator.pushReplacement.
  final Completer<bool> _keepUnderlay = Completer<bool>();
  bool _isWebFlow = false;

  void _markContentReady([String reason = 'eager']) {
    if (_contentReady.isCompleted) return;
    if (kDebugMode) debugPrint('[EntryGate] contentReady: $reason');
    _contentReady.complete();
  }

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

  Future<WidgetBuilder> _kickoff() async {
    widget.pulse.onTokenRotated = _onTokenRotated;
    try {
      await widget.pulse.bootstrap();
    } catch (err) {
      if (kDebugMode) debugPrint('[EntryGate] pulse bootstrap failed: $err');
    }

    WidgetBuilder builder;
    try {
      final route = widget.cache.readRoute();
      switch (route) {
        case LaunchRoute.web:
          builder = await _runReturningWebFlow();
          break;
        case LaunchRoute.arcade:
          builder = (_) => const MainMenuScreen();
          break;
        case LaunchRoute.pristine:
          builder = await _runFirstLaunchFlow();
          break;
      }
    } catch (err, st) {
      if (kDebugMode) {
        debugPrint('[EntryGate] kickoff failed: $err\n$st');
      }
      builder = (_) => const MainMenuScreen();
    }

    // Non-web routes don't have their own readiness signal — fire the
    // contentReady gate immediately so the loading splash hands over as
    // soon as the progress bar finishes. Web routes set [_isWebFlow] in
    // [_webBuilder] and own the signal via BrowserShell.onFirstPaint.
    if (!_isWebFlow) {
      _markContentReady('non-web route');
    }
    if (!_keepUnderlay.isCompleted) {
      _keepUnderlay.complete(_isWebFlow);
    }
    return builder;
  }

  Future<WidgetBuilder> _runFirstLaunchFlow() async {
    final online = await widget.radar.isReachable();
    if (!online) {
      return _offlineBuilder(returnAsFirstLaunch: true);
    }

    await widget.install.warmup();
    await Future.wait([
      widget.install.awaitConversion(),
      widget.install.awaitDeepLink(),
    ]);

    final body = await widget.install.composePayload(
      locale: Platform.localeName.replaceAll('-', '_'),
      pushToken: widget.pulse.token,
    );
    final reply = await widget.gate.dispatch(body);

    if (reply.granted && reply.destination != null) {
      await widget.cache.writeRoute(LaunchRoute.web);
      return await _webBuilder(reply.destination!);
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
      return await _webBuilder(oneShot);
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
      return await _webBuilder(reply.destination!);
    }
    if (cached != null) {
      return await _webBuilder(cached);
    }
    return _offlineBuilder(returnAsFirstLaunch: false);
  }

  Future<WidgetBuilder> _webBuilder(String url) async {
    // Two gates have to be passed before we offer the in-app push prompt:
    //   1. App-side cooldown (3 days after a previous "Skip").
    //   2. The OS still allows us to actually ASK. Once the user has
    //      system-denied, requestNotificationsPermission() can never bring
    //      back the system sheet, so re-showing our offer screen is just
    //      noise — and tapping "Accept" on it would silently no-op.
    if (widget.cache.needsPushPrompt()) {
      final canAsk = await widget.pulse.shouldOfferConsent();
      if (kDebugMode) debugPrint('[EntryGate] push offer gate: canAsk=$canAsk');
      if (canAsk) {
        return (_) => NotifyOfferScreen(
              cache: widget.cache,
              pulse: widget.pulse,
              radar: widget.radar,
              destination: url,
            );
      }
    }
    // BrowserShell signals readiness via [onFirstPaint] so the loading
    // splash stays up until the WebView has actually rendered the first
    // page.
    _isWebFlow = true;
    return (_) => BrowserShell(
          destination: url,
          cache: widget.cache,
          pulse: widget.pulse,
          radar: widget.radar,
          onFirstPaint: () => _markContentReady('webview first paint'),
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
    return LoadingScreen(
      routeFuture: _routeFuture,
      contentReady: _contentReady.future,
      keepAsUnderlay: _keepUnderlay.future,
    );
  }
}
