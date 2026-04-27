import 'dart:async';

import 'package:flutter/material.dart';

import '../services/network_radar.dart';

/// Shown whenever the gray flow detects the device went offline. Provides a
/// retry button that re-checks reachability and routes back via the
/// supplied [retryBuilder].
class NetworkPauseScreen extends StatefulWidget {
  final WidgetBuilder retryBuilder;
  final NetworkRadar radar;

  const NetworkPauseScreen({
    super.key,
    required this.retryBuilder,
    required this.radar,
  });

  @override
  State<NetworkPauseScreen> createState() => _NetworkPauseScreenState();
}

class _NetworkPauseScreenState extends State<NetworkPauseScreen>
    with SingleTickerProviderStateMixin {
  bool _busy = false;
  bool _hint = false;
  Timer? _hintTimer;
  late final AnimationController _press;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 130),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.94).animate(
      CurvedAnimation(parent: _press, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _press.dispose();
    super.dispose();
  }

  Future<void> _retry() async {
    if (_busy) return;
    await _press.forward();
    await _press.reverse();
    if (!mounted) return;
    setState(() => _busy = true);

    final online = await widget.radar.isReachable();
    if (!mounted) return;

    if (!online) {
      _hintTimer?.cancel();
      setState(() {
        _busy = false;
        _hint = true;
      });
      _hintTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _hint = false);
      });
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: widget.retryBuilder),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const _PauseShell().wrap(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: LayoutBuilder(
            builder: (ctx, _) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.cloud_off_rounded,
                  color: Colors.white70,
                  size: 88,
                ),
                const SizedBox(height: 24),
                const Text(
                  'No connection',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                AnimatedOpacity(
                  opacity: _hint ? 1.0 : 0.6,
                  duration: const Duration(milliseconds: 250),
                  child: const Text(
                    'Please check your internet and try again.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                ScaleTransition(
                  scale: _scale,
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: _busy
                            ? null
                            : const LinearGradient(
                                colors: [
                                  Color(0xFFFFC107),
                                  Color(0xFFFF8A00),
                                ],
                              ),
                        color: _busy
                            ? Colors.amber.withValues(alpha: 0.3)
                            : null,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: _busy
                            ? const []
                            : [
                                BoxShadow(
                                  color:
                                      Colors.amber.withValues(alpha: 0.35),
                                  blurRadius: 18,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: _busy ? null : _retry,
                          child: Center(
                            child: _busy
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      valueColor:
                                          AlwaysStoppedAnimation<Color>(
                                              Colors.white),
                                    ),
                                  )
                                : const Text(
                                    'Retry',
                                    style: TextStyle(
                                      color: Colors.black,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 2,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PauseShell {
  const _PauseShell();

  Widget wrap({required Widget child}) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0F1F),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [Color(0xFF14213D), Color(0xFF050912)],
                radius: 1.1,
                center: Alignment.center,
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}
