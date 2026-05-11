import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Minimal built-in splash used while the gray boot pipeline runs. The host
/// app SHOULD replace this with its branded loading screen by passing
/// `splashBuilder` to [EntryGate], but the default is good enough for a
/// reference / template build.
///
/// Lifecycle contract (mirrors what the host's branded splash must honour):
///
///   • The splash MUST stay on screen until BOTH [routeFuture] resolves AND
///     [contentReady] completes. This is what keeps the loading bar visible
///     while the WebView paints its first page, so the user never sees a
///     "100 % bar → black screen → web shows up" stutter.
///
///   • If [keepAsUnderlay] resolves to `true`, the resolved widget MUST be
///     mounted UNDERNEATH the splash before the splash fades out — otherwise
///     the WebView gets torn down and re-created during the handover and
///     loses its loaded page.
///
///   • Whenever [keepAsUnderlay] resolves to `false`, the splash should hand
///     over via `Navigator.pushReplacement` so the resolved widget becomes a
///     top-level route (any further `Navigator.of(context).push…` from it
///     does not climb back into the splash's element tree).
///
///   • [contentReady] has a hard timeout — the splash MUST hand over even if
///     the readiness signal never arrives, otherwise a silently-broken
///     WebView would lock the user on the splash forever.
class DefaultGraySplash extends StatefulWidget {
  final Future<WidgetBuilder>? routeFuture;
  final Future<void>? contentReady;
  final Future<bool>? keepAsUnderlay;

  const DefaultGraySplash({
    super.key,
    this.routeFuture,
    this.contentReady,
    this.keepAsUnderlay,
  });

  @override
  State<DefaultGraySplash> createState() => _DefaultGraySplashState();
}

class _DefaultGraySplashState extends State<DefaultGraySplash>
    with SingleTickerProviderStateMixin {
  // The bar always animates for at least this long so the visual transition
  // never looks like a stutter even when the boot pipeline finishes instantly.
  static const Duration _minProgressDuration = Duration(milliseconds: 2200);
  // Hard ceiling we'll wait for `contentReady`. Beyond this we hand over
  // regardless so a silently broken WebView can't lock the user on the splash.
  static const Duration _contentReadyDeadline = Duration(seconds: 12);

  late final AnimationController _progress;
  bool _routeReady = false;
  bool _contentReady = false;
  bool _navigated = false;
  bool _splashVisible = true;
  bool _useUnderlay = false;
  bool? _keepDecision;
  WidgetBuilder? _resolvedBuilder;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _progress = AnimationController(vsync: this, duration: _minProgressDuration)
      ..addListener(() {
        if (mounted) setState(() {});
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _maybeGoNext();
      })
      ..forward();

    final route = widget.routeFuture;
    if (route == null) {
      _routeReady = true;
    } else {
      route.then((builder) {
        if (!mounted) return;
        setState(() {
          _resolvedBuilder = builder;
          _routeReady = true;
        });
        _maybeGoNext();
      }).catchError((_) {
        if (!mounted) return;
        setState(() => _routeReady = true);
        _maybeGoNext();
      });
    }

    final keep = widget.keepAsUnderlay;
    if (keep == null) {
      _keepDecision = false;
    } else {
      keep.then((v) {
        if (!mounted) return;
        setState(() => _keepDecision = v);
      }).catchError((_) {
        if (!mounted) return;
        setState(() => _keepDecision = false);
      });
    }

    final ready = widget.contentReady;
    if (ready == null) {
      _contentReady = true;
    } else {
      ready.timeout(_contentReadyDeadline, onTimeout: () {}).then((_) {
        if (!mounted) return;
        setState(() => _contentReady = true);
        _maybeGoNext();
      }).catchError((_) {
        if (!mounted) return;
        setState(() => _contentReady = true);
        _maybeGoNext();
      });
    }
  }

  void _maybeGoNext() {
    if (_navigated) return;
    if (_progress.status != AnimationStatus.completed) return;
    if (!_routeReady) return;
    if (!_contentReady) return;
    _goNext();
  }

  Future<void> _goNext() async {
    if (_navigated) return;
    _navigated = true;

    bool keep = false;
    final keepFuture = widget.keepAsUnderlay;
    if (keepFuture != null) {
      try {
        keep = await keepFuture.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => false,
        );
      } catch (_) {
        keep = false;
      }
    }
    if (!mounted) return;

    if (keep) {
      setState(() => _useUnderlay = true);
      return;
    }

    final builder =
        _resolvedBuilder ?? (_) => const _GrayDefaultEmptyHome();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (context, a, b) => Builder(builder: builder),
        transitionsBuilder: (context, anim, b, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Widget _buildSplash(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final compact = size.shortestSide < 360;
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0B1326), Color(0xFF06080F)],
            ),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: compact ? 40 : 56,
                height: compact ? 40 : 56,
                child: const CircularProgressIndicator(
                  strokeWidth: 3.2,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(Color(0xFFFFC44E)),
                ),
              ),
              SizedBox(height: compact ? 18 : 26),
              SizedBox(
                width: size.shortestSide * 0.55,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _progress.value,
                    minHeight: 6,
                    backgroundColor: const Color(0x33FFFFFF),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFFFFC44E),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final renderUnderlay = _keepDecision == true && _resolvedBuilder != null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (renderUnderlay)
            Positioned.fill(child: Builder(builder: _resolvedBuilder!)),
          if (_splashVisible)
            Positioned.fill(
              child: AbsorbPointer(
                absorbing: !_useUnderlay,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 400),
                  opacity: _useUnderlay ? 0.0 : 1.0,
                  onEnd: () {
                    if (!mounted || !_splashVisible) return;
                    if (_useUnderlay) {
                      setState(() => _splashVisible = false);
                    }
                  },
                  child: _buildSplash(context),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Last-resort fallback when the host did not provide a `fallbackHomeBuilder`
/// AND the route resolver itself produced no widget. In a real integration
/// this is never reached.
class _GrayDefaultEmptyHome extends StatelessWidget {
  const _GrayDefaultEmptyHome();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Text(
          'Gray flow: no host home configured.',
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );
  }
}
