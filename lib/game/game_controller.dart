import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'board.dart';
import 'constants.dart';
import 'piece.dart';
import 'tetromino.dart';

enum GameStatus { playing, paused, gameOver }

class GameController extends ChangeNotifier {
  final Board board = Board();
  final Random _random = Random();

  Piece? current;
  Piece? next;

  int score = 0;
  int level = 1;
  int lines = 0;
  int bestScore = 0;

  GameStatus status = GameStatus.playing;

  Timer? _frameTimer;
  final Stopwatch _sw = Stopwatch();

  double _fallAccum = 0.0;
  bool _lockFlash = false;
  bool _softDropping = false;

  static const double _softDropMultiplier = 4.0;

  // Lock-delay safeguard. Once a piece is grounded (cannot move down) the
  // player is allowed a small number of lateral / rotation adjustments before
  // the piece is force-locked. This prevents abusing rotation kicks and rapid
  // tap spam to indefinitely shift a piece past already placed blocks.
  int _lockResets = 0;
  static const int _maxLockResets = 4;
  // After a piece is grounded we wait at most this many seconds before forcing
  // a lock, regardless of player input. This makes a piece fall "naturally"
  // even at low gravity once it has come to rest on a stack.
  double _groundedTime = 0.0;
  static const double _maxGroundedSeconds = 0.45;

  GameController() {
    _loadBest();
    _spawn();
    _startLoop();
  }

  double get fallProgress => _fallAccum;

  double get renderFallProgress {
    final p = current;
    if (p == null) return 0;
    final below = p.copyWith(row: p.row + 1);
    if (!board.canPlace(below)) return 0;
    return _fallAccum.clamp(0.0, 1.0);
  }

  bool get lockFlash => _lockFlash;

  Duration get _interval {
    final ms = max(120, 800 - (level - 1) * 60);
    return Duration(milliseconds: ms);
  }

  Future<void> _loadBest() async {
    final prefs = await SharedPreferences.getInstance();
    bestScore = prefs.getInt(kBestScoreKey) ?? 0;
    notifyListeners();
  }

  Future<void> _saveBestIfNeeded() async {
    if (score > bestScore) {
      bestScore = score;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(kBestScoreKey, bestScore);
    }
  }

  void _startLoop() {
    _frameTimer?.cancel();
    _sw
      ..reset()
      ..start();
    _frameTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _onFrame(),
    );
  }

  void _stopLoop() {
    _frameTimer?.cancel();
    _frameTimer = null;
    _sw.stop();
  }

  void _onFrame() {
    if (status != GameStatus.playing) return;
    final elapsedMicros = _sw.elapsedMicroseconds;
    _sw
      ..reset()
      ..start();
    final dtMs = elapsedMicros / 1000.0;
    final speedMul = _softDropping ? _softDropMultiplier : 1.0;
    _fallAccum += (dtMs / _interval.inMilliseconds) * speedMul;

    bool anyStep = false;
    while (_fallAccum >= 1.0) {
      _fallAccum -= 1.0;
      _step();
      anyStep = true;
      if (status != GameStatus.playing) break;
    }

    // While the piece is grounded, accumulate "rest" time. Once we've sat on
    // top of a stack for too long we force a lock even if the player keeps
    // spamming rotations.
    if (status == GameStatus.playing && _isGrounded()) {
      _groundedTime += dtMs / 1000.0;
      if (_groundedTime >= _maxGroundedSeconds) {
        _lock();
        anyStep = true;
      }
    } else {
      _groundedTime = 0.0;
    }

    if (!anyStep) {
      notifyListeners();
    }
  }

  bool _isGrounded() {
    final p = current;
    if (p == null) return false;
    return !board.canPlace(p.copyWith(row: p.row + 1));
  }

  void _spawn() {
    _fallAccum = 0.0;
    _lockResets = 0;
    _groundedTime = 0.0;
    current = next ?? Piece.spawn(randomTetromino(), _random);
    next = Piece.spawn(randomTetromino(), _random);
    if (!board.canPlace(current!)) {
      status = GameStatus.gameOver;
      _stopLoop();
      _saveBestIfNeeded();
    }
  }

  void _step() {
    if (status != GameStatus.playing) return;
    final moved = current!.copyWith(row: current!.row + 1);
    if (board.canPlace(moved)) {
      current = moved;
      _lockResets = 0;
      _groundedTime = 0.0;
    } else {
      _lock();
    }
    notifyListeners();
  }

  void _lock() {
    board.merge(current!);
    final cleared = board.clearLines();
    if (cleared > 0) {
      lines += cleared;
      score += (100 * cleared * cleared) * level;
      final newLevel = 1 + (lines ~/ 10);
      if (newLevel != level) {
        level = newLevel;
      }
    } else {
      score += 5 * level;
    }
    _lockFlash = true;
    Future.delayed(const Duration(milliseconds: 80), () {
      _lockFlash = false;
      if (status == GameStatus.playing) notifyListeners();
    });
    _spawn();
    // _spawn() may flip status to gameOver and stop the frame loop; if so,
    // the only thing standing between the user and an apparently frozen
    // screen is this notification. Without it the hang reproduces every
    // time a tower tops out from natural gravity (no soft-drop, no rotation
    // input — those paths each call notifyListeners themselves).
    notifyListeners();
  }

  void moveLeft() {
    if (status != GameStatus.playing) return;
    if (_consumeLockResetIfGrounded()) return;
    final m = current!.copyWith(col: current!.col - 1);
    if (board.canPlace(m)) {
      current = m;
      notifyListeners();
    }
  }

  void moveRight() {
    if (status != GameStatus.playing) return;
    if (_consumeLockResetIfGrounded()) return;
    final m = current!.copyWith(col: current!.col + 1);
    if (board.canPlace(m)) {
      current = m;
      notifyListeners();
    }
  }

  /// Charges one lock-reset slot when the piece is currently grounded.
  /// Returns true if the lock budget was exhausted and the piece was locked
  /// in place — caller should abort its action in that case.
  bool _consumeLockResetIfGrounded() {
    if (!_isGrounded()) return false;
    _lockResets++;
    if (_lockResets > _maxLockResets) {
      _lock();
      notifyListeners();
      return true;
    }
    return false;
  }

  void setSoftDrop(bool enabled) {
    if (_softDropping == enabled) return;
    _softDropping = enabled;
  }

  void softDropStep() {
    if (status != GameStatus.playing) return;
    final moved = current!.copyWith(row: current!.row + 1);
    if (board.canPlace(moved)) {
      current = moved;
      _fallAccum = 0;
      score += 1;
      notifyListeners();
    }
  }

  void hardDrop() {
    if (status != GameStatus.playing) return;
    int dropped = 0;
    while (true) {
      final m = current!.copyWith(row: current!.row + 1);
      if (board.canPlace(m)) {
        current = m;
        dropped++;
      } else {
        break;
      }
    }
    score += dropped * 2;
    _fallAccum = 0;
    _lock();
    notifyListeners();
  }

  void rotate() {
    if (status != GameStatus.playing) return;
    final rotations = current!.def.rotations.length;
    if (rotations <= 1) return;
    if (_consumeLockResetIfGrounded()) return;
    final newRot = (current!.rotation + 1) % rotations;
    // Tight wall-kick: only allow the in-place rotation plus a single-cell
    // nudge to either side. Larger kicks were enabling pieces to tunnel past
    // already-stacked blocks via rotation spam.
    for (final dx in const [0, -1, 1]) {
      final candidate = current!.copyWith(
        rotation: newRot,
        col: current!.col + dx,
      );
      if (board.canPlace(candidate)) {
        current = candidate;
        notifyListeners();
        return;
      }
    }
  }

  void pause() {
    if (status != GameStatus.playing) return;
    status = GameStatus.paused;
    _softDropping = false;
    _stopLoop();
    notifyListeners();
  }

  void resume() {
    if (status != GameStatus.paused) return;
    status = GameStatus.playing;
    _startLoop();
    notifyListeners();
  }

  void restart() {
    _stopLoop();
    board.reset();
    score = 0;
    level = 1;
    lines = 0;
    current = null;
    next = null;
    _fallAccum = 0;
    _lockResets = 0;
    _groundedTime = 0.0;
    status = GameStatus.playing;
    _spawn();
    _startLoop();
    notifyListeners();
  }

  @override
  void dispose() {
    _stopLoop();
    super.dispose();
  }
}
