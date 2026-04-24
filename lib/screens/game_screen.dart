import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../game/game_controller.dart';
import '../widgets/control_bar.dart';
import '../widgets/game_board_view.dart';
import '../widgets/game_over_overlay.dart';
import '../widgets/hud.dart';
import '../widgets/pause_overlay.dart';
import '../widgets/scene_background.dart';

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late final GameController _controller;

  double _horizAccum = 0;
  double _vertAccum = 0;
  bool _hardDropFired = false;
  bool _gestureSoftDrop = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _controller = GameController();
    _controller.addListener(_onStateChanged);
  }

  void _onStateChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onStateChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (_controller.status == GameStatus.playing) {
      _controller.rotate();
    }
  }

  void _onPanStart(DragStartDetails d) {
    _horizAccum = 0;
    _vertAccum = 0;
    _hardDropFired = false;
  }

  void _onPanUpdate(DragUpdateDetails d, double cellSize) {
    _horizAccum += d.delta.dx;
    _vertAccum += d.delta.dy;

    while (_horizAccum.abs() > cellSize * 0.75) {
      if (_horizAccum > 0) {
        _controller.moveRight();
        _horizAccum -= cellSize;
      } else {
        _controller.moveLeft();
        _horizAccum += cellSize;
      }
    }

    if (!_hardDropFired && _vertAccum > cellSize * 0.4 && !_gestureSoftDrop) {
      _gestureSoftDrop = true;
      _controller.setSoftDrop(true);
    }
  }

  void _onPanEnd(DragEndDetails d) {
    if (_gestureSoftDrop) {
      _gestureSoftDrop = false;
      _controller.setSoftDrop(false);
    }
    final v = d.velocity.pixelsPerSecond.dy;
    if (v > 1800 && !_hardDropFired) {
      _controller.hardDrop();
      _hardDropFired = true;
    }
  }

  void _onPanCancel() {
    if (_gestureSoftDrop) {
      _gestureSoftDrop = false;
      _controller.setSoftDrop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final cellSize = constraints.maxWidth * 0.78 / 8;
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _handleTap,
                onPanStart: _onPanStart,
                onPanUpdate: (d) => _onPanUpdate(d, cellSize),
                onPanEnd: _onPanEnd,
                onPanCancel: _onPanCancel,
                child: SceneBackground(
                  fieldOverlay: GameBoardView(controller: _controller),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Hud(
                  score: _controller.score,
                  level: _controller.level,
                  lines: _controller.lines,
                  best: _controller.bestScore,
                  onPause: _controller.pause,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ControlBar(
                  onLeft: _controller.moveLeft,
                  onRight: _controller.moveRight,
                  onRotate: _controller.rotate,
                  onSoftDrop: _controller.setSoftDrop,
                  onHardDrop: _controller.hardDrop,
                ),
              ),
              if (_controller.status == GameStatus.paused)
                PauseOverlay(
                  onResume: _controller.resume,
                  onMenu: _backToMenu,
                ),
              if (_controller.status == GameStatus.gameOver)
                GameOverOverlay(
                  score: _controller.score,
                  best: _controller.bestScore,
                  onRetry: _controller.restart,
                  onMenu: _backToMenu,
                ),
            ],
          );
        },
      ),
    );
  }

  void _backToMenu() {
    Navigator.of(context).pop();
  }
}
