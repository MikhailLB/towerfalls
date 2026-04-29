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
class LoadingScreen extends StatefulWidget {
  final Future<WidgetBuilder>? routeFuture;

  const LoadingScreen({super.key, this.routeFuture});

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _video;
  late final AnimationController _progress;
  Orientation? _loadedOrientation;
  bool _loadingVideo = false;
  bool _videoFailed = false;
  bool _progressStarted = false;
  bool _navigated = false;

  WidgetBuilder? _resolvedBuilder;
  bool _routeReady = false;

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
        _resolvedBuilder = builder;
        _routeReady = true;
        _maybeGoNext();
      }).catchError((err, st) {
        debugPrint('[LoadingScreen] route resolver failed: $err\n$st');
        if (!mounted) return;
        _routeReady = true;
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
    _goNext();
  }

  Future<void> _goNext() async {
    if (_navigated) return;
    _navigated = true;
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

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    final landscape = orientation == Orientation.landscape;
    final video = _video;
    final videoReady = video != null && video.value.isInitialized;
    final screenReady = videoReady || _videoFailed;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
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
          AnimatedOpacity(
            duration: const Duration(milliseconds: 300),
            opacity: screenReady ? 1 : 0,
            child: Align(
              alignment: Alignment(0, landscape ? 0.85 : 0.92),
              child: Text(
                'LOADING  ${(_progress.value * 100).clamp(0, 100).toInt()}%',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: landscape ? 12 : 14,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
