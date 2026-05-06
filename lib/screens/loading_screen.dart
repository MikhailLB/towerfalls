import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../game/constants.dart';
import '../widgets/loading_bar.dart';
import 'main_menu_screen.dart';

/// Branded loading splash. Plays the orientation-matched intro video and
/// animates the engraved progress bar; once both the bar animation and the
/// optional [routeFuture] have completed, navigates to the resolved page.
///
/// When [routeFuture] is null the screen falls back to the regular game
/// entrypoint (main menu).
///
/// When [contentReady] is provided AND [keepAsUnderlay] resolves to true the
/// splash mounts the resolved widget underneath itself as soon as
/// [routeFuture] resolves and only fades out after [contentReady] also
/// completes (with a hard timeout fallback). This is what the gray flow uses
/// to keep the splash visible until the WebView has actually painted its
/// first page, so the bar never reaches 100% before the underlying content
/// is on screen.
///
/// For routes that don't need to preserve their state across the handover
/// (e.g. the arcade MainMenu, the offline NetworkPause screen), the underlay
/// trick is skipped — those use the classic [Navigator.pushReplacement] path
/// so they end up as proper top-level routes (otherwise pushing further
/// routes from a deeply-nested Builder context can hang on iOS).
class LoadingScreen extends StatefulWidget {
  final Future<WidgetBuilder>? routeFuture;
  final Future<void>? contentReady;
  // Resolves to true when the resolved widget is something we MUST keep
  // mounted (so it doesn't lose state on handover — i.e. WebView). When
  // false / null we fall back to Navigator.pushReplacement.
  final Future<bool>? keepAsUnderlay;

  const LoadingScreen({
    super.key,
    this.routeFuture,
    this.contentReady,
    this.keepAsUnderlay,
  });

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with SingleTickerProviderStateMixin {
  // Hard ceiling we wait for [contentReady]. If the underlay never signals
  // (e.g. WebView crashed silently) the splash still hands over so the user
  // is not stuck on a loading bar forever. Tightened from 12s → 6s — a
  // healthy WebView paints inside 2-3s and the worst-case fallback to the
  // arcade flow is fine when something has actually broken.
  static const Duration _contentReadyDeadline = Duration(seconds: 6);

  VideoPlayerController? _video;
  late final AnimationController _progress;
  Orientation? _loadedOrientation;
  bool _loadingVideo = false;
  bool _videoFailed = false;
  bool _progressStarted = false;
  bool _navigated = false;

  WidgetBuilder? _resolvedBuilder;
  bool _routeReady = false;
  bool _contentReady = false;
  bool _splashVisible = true;
  // Resolved at handover time. Defaults to false — we only switch to underlay
  // mode when [keepAsUnderlay] explicitly resolves true.
  bool _useUnderlay = false;
  // null = decision not yet known, true/false = decided. We only mount the
  // resolved widget as an underlay when this is explicitly true; otherwise
  // it stays out of the tree entirely and gets promoted via pushReplacement
  // (which is what every non-web route in the gray flow expects).
  bool? _keepDecision;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _progress = AnimationController(
      vsync: this,
      duration: kLoadingMinDuration,
    )
      ..addListener(() {
        if (mounted) setState(() {});
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _maybeGoNext();
      });

    final future = widget.routeFuture;
    if (future == null) {
      _routeReady = true;
    } else {
      future.then((builder) {
        if (!mounted) return;
        setState(() {
          _resolvedBuilder = builder;
          _routeReady = true;
        });
        _maybeGoNext();
      }).catchError((err, st) {
        debugPrint('[LoadingScreen] route resolver failed: $err\n$st');
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
      ready.timeout(_contentReadyDeadline, onTimeout: () {
        debugPrint('[LoadingScreen] contentReady timeout — handing over');
      }).then((_) {
        if (!mounted) return;
        setState(() => _contentReady = true);
        _maybeGoNext();
      }).catchError((err) {
        debugPrint('[LoadingScreen] contentReady error: $err');
        if (!mounted) return;
        setState(() => _contentReady = true);
        _maybeGoNext();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final orientation = MediaQuery.of(context).orientation;
    if (!_loadingVideo && _loadedOrientation != orientation) {
      _loadVideo(orientation);
    }
  }

  void _startProgressIfNeeded() {
    if (_progressStarted) return;
    _progressStarted = true;
    _progress.forward();
  }

  Future<void> _loadVideo(Orientation orientation) async {
    _loadingVideo = true;
    final path = orientation == Orientation.landscape
        ? kLoadingVideoLandscape
        : kLoadingVideoPortrait;

    final previous = _video;
    final controller = VideoPlayerController.asset(path);
    try {
      await controller.initialize().timeout(const Duration(seconds: 6));
      await controller.setLooping(true);
      await controller.setVolume(0.0);
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _video = controller;
        _loadedOrientation = orientation;
        _videoFailed = false;
      });
      await previous?.dispose();
      _startProgressIfNeeded();
    } catch (e, st) {
      debugPrint('Loading video failed ($path): $e\n$st');
      await controller.dispose();
      if (mounted) {
        setState(() {
          _loadedOrientation = orientation;
          _videoFailed = true;
        });
      }
      _startProgressIfNeeded();
    } finally {
      _loadingVideo = false;
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

    // Decide handover mode: keep mounted as underlay (state-preserving) or
    // promote to its own route via pushReplacement (default).
    bool keep = false;
    final keepFuture = widget.keepAsUnderlay;
    if (keepFuture != null) {
      try {
        keep = await keepFuture
            .timeout(const Duration(milliseconds: 500), onTimeout: () => false);
      } catch (_) {
        keep = false;
      }
    }
    if (!mounted) return;

    if (keep) {
      // Underlay mode — the resolved widget is already mounted beneath the
      // splash. Just fade the splash out; AnimatedOpacity.onEnd removes it
      // from the tree and disposes the heavy bits (video player, ticker).
      setState(() => _useUnderlay = true);
      return;
    }

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    if (!mounted) return;
    final builder = _resolvedBuilder ?? (_) => const MainMenuScreen();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (context, a, b) => Builder(builder: builder),
        transitionsBuilder: (context, anim, b, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  // Free the loading-splash assets the moment we no longer need them. Without
  // this the AVPlayer + Ticker keep running for the whole session in underlay
  // mode and on iOS they meaningfully fight the game / WebView for resources
  // (frame drops, occasional input deadlocks).
  Future<void> _disposeSplashAssets() async {
    final video = _video;
    _video = null;
    try {
      _progress.stop();
    } catch (_) {}
    try {
      await video?.pause();
    } catch (_) {}
    try {
      await video?.dispose();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _video?.dispose();
    _progress.dispose();
    super.dispose();
  }

  Widget _buildSplash(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    final landscape = orientation == Orientation.landscape;
    final video = _video;
    final videoReady = video != null && video.value.isInitialized;
    final screenReady = videoReady || _videoFailed;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (videoReady)
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: video.value.size.width,
              height: video.value.size.height,
              child: VideoPlayer(video),
            ),
          )
        else if (_videoFailed)
          Image.asset(kBgAsset, fit: BoxFit.cover)
        else
          const ColoredBox(color: Colors.black),
        if (screenReady)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.0),
                      Colors.black.withValues(alpha: 0.55),
                    ],
                  ),
                ),
              ),
            ),
          ),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 300),
          opacity: screenReady ? 1 : 0,
          child: Align(
            alignment: Alignment(0, landscape ? 0.40 : 0.55),
            child: _buildDropZoneBadge(landscape: landscape),
          ),
        ),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 300),
          opacity: screenReady ? 1 : 0,
          child: Align(
            alignment: Alignment(0, landscape ? 0.62 : 0.75),
            child: FractionallySizedBox(
              widthFactor: landscape ? 0.30 : 0.72,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: landscape ? 70 : 96,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: LoadingBar(progress: _progress.value),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDropZoneBadge({required bool landscape}) {
    final fontSize = landscape ? 18.0 : 26.0;
    return Text(
      'DROP ZONE',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w900,
        letterSpacing: 6,
        color: const Color(0xFFFFC04A),
        shadows: const [
          Shadow(
            color: Color(0xFFFF6A00),
            blurRadius: 14,
            offset: Offset(0, 1),
          ),
          Shadow(
            color: Colors.black,
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Single, stable tree shape so the underlay widget (e.g. BrowserShell
    // hosting a WKWebView) keeps the same Element across the splash → ready
    // mode switch and never gets re-mounted (which would tear down the
    // WebView and lose its loading state). We only mount it when the host
    // explicitly asked for underlay mode (web flow); otherwise the resolved
    // widget is launched via Navigator.pushReplacement in [_goNext].
    final renderUnderlay =
        _keepDecision == true && _resolvedBuilder != null;

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
                  onEnd: () async {
                    if (!mounted || !_splashVisible) return;
                    if (_useUnderlay) {
                      setState(() => _splashVisible = false);
                      await _disposeSplashAssets();
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
