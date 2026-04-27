import 'dart:io';

import 'package:flutter/material.dart';

import '../../screens/loading_screen.dart';
import '../models/launch_route.dart';
import '../services/install_signal_client.dart';
import '../services/network_radar.dart';
import '../services/pulse_dispatch.dart';
import '../services/remote_gate_client.dart';
import '../services/runtime_cache.dart';
import 'browser_shell.dart';
import 'network_pause_screen.dart';
import 'notify_offer_screen.dart';

enum _GateStage { warming, dispatching, settling }

/// First widget rendered in the gray flow. Resolves the launch route in the
/// background while showing a minimal animated splash so the user perceives
/// progress instead of a freeze.
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

class _EntryGateState extends State<EntryGate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spinner;
  _GateStage _stage = _GateStage.warming;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _spinner = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _kickoff();
  }

  @override
  void dispose() {
    widget.pulse.onTokenRotated = null;
    _spinner.dispose();
    super.dispose();
  }

  void _setStage(_GateStage s) {
    if (mounted) setState(() => _stage = s);
  }

  Future<void> _kickoff() async {
    widget.pulse.onTokenRotated = _onTokenRotated;
    await widget.pulse.bootstrap().catchError((_) {});

    final route = widget.cache.readRoute();
    switch (route) {
      case LaunchRoute.web:
        await _runReturningWebFlow();
        break;
      case LaunchRoute.arcade:
        _setStage(_GateStage.settling);
        await Future.delayed(const Duration(milliseconds: 350));
        _goArcade();
        break;
      case LaunchRoute.pristine:
        await _runFirstLaunchFlow();
        break;
    }
  }

  Future<void> _runFirstLaunchFlow() async {
    _setStage(_GateStage.warming);

    final online = await widget.radar.isReachable();
    if (!online) {
      _routeOffline(returnAsFirstLaunch: true);
      return;
    }

    _setStage(_GateStage.dispatching);
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
      _setStage(_GateStage.settling);
      await Future.delayed(const Duration(milliseconds: 320));
      _goWeb(reply.destination!);
    } else {
      await widget.cache.writeRoute(LaunchRoute.arcade);
      _setStage(_GateStage.settling);
      await Future.delayed(const Duration(milliseconds: 320));
      _goArcade();
    }
  }

  Future<void> _runReturningWebFlow() async {
    _setStage(_GateStage.dispatching);

    final online = await widget.radar.isReachable();
    if (!online) {
      _setStage(_GateStage.settling);
      await Future.delayed(const Duration(milliseconds: 280));
      _routeOffline(returnAsFirstLaunch: false);
      return;
    }

    final oneShot = await widget.cache.consumeOneShotPush();
    if (oneShot != null) {
      _setStage(_GateStage.settling);
      await Future.delayed(const Duration(milliseconds: 280));
      _goWeb(oneShot);
      return;
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

    _setStage(_GateStage.settling);
    await Future.delayed(const Duration(milliseconds: 280));
    if (!mounted) return;

    if (reply.granted && reply.destination != null) {
      _goWeb(reply.destination!);
      return;
    }
    if (cached != null) {
      _goWeb(cached);
    } else {
      _routeOffline(returnAsFirstLaunch: false);
    }
  }

  void _onTokenRotated(String fresh) async {
    final body = await widget.install.composePayload(
      locale: Platform.localeName.replaceAll('-', '_'),
      pushToken: fresh,
    );
    widget.gate.dispatch(body);
  }

  void _goWeb(String url) {
    if (_leaving || !mounted) return;
    _leaving = true;
    final builder = widget.cache.needsPushPrompt()
        ? (_) => NotifyOfferScreen(
              cache: widget.cache,
              pulse: widget.pulse,
              radar: widget.radar,
              destination: url,
            )
        : (_) => BrowserShell(
              destination: url,
              cache: widget.cache,
              pulse: widget.pulse,
              radar: widget.radar,
            );
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: builder));
  }

  void _goArcade() {
    if (_leaving || !mounted) return;
    _leaving = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoadingScreen()),
    );
  }

  void _routeOffline({required bool returnAsFirstLaunch}) {
    if (_leaving || !mounted) return;
    _leaving = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => NetworkPauseScreen(
          radar: widget.radar,
          retryBuilder: (_) => EntryGate(
            cache: widget.cache,
            radar: widget.radar,
            install: widget.install,
            gate: widget.gate,
            pulse: widget.pulse,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050912),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [Color(0xFF14213D), Color(0xFF050912)],
                radius: 1.2,
                center: Alignment.center,
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/logo/logo_name.webp',
                  width: 220,
                  fit: BoxFit.contain,
                  errorBuilder: (_, e, s) => const Text(
                    'Tower Falls',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                _RingIndicator(controller: _spinner, stage: _stage),
                const SizedBox(height: 18),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  child: Text(
                    _labelFor(_stage),
                    key: ValueKey(_stage),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      letterSpacing: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _labelFor(_GateStage stage) {
    switch (stage) {
      case _GateStage.warming:
        return 'Preparing the tower…';
      case _GateStage.dispatching:
        return 'Syncing with servers…';
      case _GateStage.settling:
        return 'Almost there';
    }
  }
}

class _RingIndicator extends StatelessWidget {
  final AnimationController controller;
  final _GateStage stage;

  const _RingIndicator({required this.controller, required this.stage});

  @override
  Widget build(BuildContext context) {
    final progress = switch (stage) {
      _GateStage.warming => 0.25,
      _GateStage.dispatching => 0.65,
      _GateStage.settling => 1.0,
    };

    return SizedBox(
      width: 56,
      height: 56,
      child: AnimatedBuilder(
        animation: controller,
        builder: (_, _) {
          return Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: 1.0,
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(
                  Colors.white.withValues(alpha: 0.08),
                ),
              ),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress),
                duration: const Duration(milliseconds: 600),
                builder: (_, value, _) => SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(
                    value: value,
                    strokeWidth: 3,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFFFFC107),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
