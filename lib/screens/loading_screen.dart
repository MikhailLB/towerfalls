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
/// When [contentReady] is provided the splash mounts the resolved widget
/// underneath itself as soon as [routeFuture] resolves and only fades out
/// after [contentReady] also completes (with a hard timeout fallback). This
/// is what the gray flow uses to keep the splash visible until the WebView
/// has actually painted its first page, so the bar never reaches 100%
/// before the underlying content is on screen.
class LoadingScreen extends StatefulWidget {
  final Future<WidgetBuilder>? routeFuture;
  final Future<void>? contentReady;

  const LoadingScreen({
    super.key,
    this.routeFuture,
    this.contentReady,
  });

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with SingleTickerProviderStateMixin {
  // Hard ceiling we wait for [contentReady]. If the underlay never signals
  // (e.g. WebView crashed silently) the splash still hands over so the user
  // is not stuck on a loading bar forever.
  static const Duration _contentReadyDeadline = Duration(seconds: 12);

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

    // When [contentReady] was provided, the resolved widget is already mounted
    // underneath us — just fade the splash out and remove the splash widgets
    // from the tree. No Navigator transition: the underlay stays exactly where
    // it is so the WebView keeps its state.
    if (widget.contentReady != null) {
      // The resolved widget owns the screen now and is responsible for its
      // own orientation/UI chrome (BrowserShell relocks landscape, the
      // arcade screens relock portrait, etc.). Just trigger the
      // AnimatedOpacity fade-out; the actual removal from the tree happens
      // in its onEnd callback.
      if (mounted) setState(() {});
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

  @override
  Widget build(BuildContext context) {
    final useUnderlay = widget.contentReady != null;

    if (useUnderlay) {
      // Underlay-mode: when the resolved widget is known, mount it BEHIND the
      // splash so it can start loading (e.g. WebView fetches the URL) while
      // the user still sees the loading video. After both progress + content
      // are ready, the splash is fully removed from the tree, leaving just
      // the underlay.
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (_resolvedBuilder != null)
              Positioned.fill(child: Builder(builder: _resolvedBuilder!)),
            if (_splashVisible)
              Positioned.fill(
                // While the splash is on top, swallow all touches so the user
                // can't tap "through" into the still-loading underlay.
                child: AbsorbPointer(
                  absorbing: !_navigated,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 400),
                    opacity: _navigated ? 0.0 : 1.0,
                    onEnd: () {
                      if (_navigated && mounted && _splashVisible) {
                        // After fade completes, kill the splash (and free the
                        // video player) so it stops drawing entirely.
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: _buildSplash(context),
    );
  }
}
