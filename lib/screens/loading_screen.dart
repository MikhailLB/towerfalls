import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../game/constants.dart';
import '../widgets/loading_bar.dart';
import 'main_menu_screen.dart';

class LoadingScreen extends StatefulWidget {
  const LoadingScreen({super.key});

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

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
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
        if (status == AnimationStatus.completed) _goNext();
      });
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

  Future<void> _goNext() async {
    if (_navigated) return;
    _navigated = true;
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (context, a, b) => const MainMenuScreen(),
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
              alignment: const Alignment(0, 0.75),
              child: FractionallySizedBox(
                widthFactor:
                    orientation == Orientation.landscape ? 0.45 : 0.72,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: LoadingBar(progress: _progress.value),
                ),
              ),
            ),
          ),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 300),
            opacity: screenReady ? 1 : 0,
            child: Align(
              alignment: const Alignment(0, 0.92),
              child: Text(
                'LOADING  ${(_progress.value * 100).clamp(0, 100).toInt()}%',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
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
