import 'dart:async';

import 'package:flutter/material.dart';

import '../../game/constants.dart';
import '../services/network_radar.dart';

/// Shown whenever the gray flow detects the device went offline. The artwork
/// already contains the headline / illustration; we render the supplied
/// "Retry" plate centered below the engraved panel.
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

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 130),
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
    return Scaffold(
      backgroundColor: const Color(0xFF050912),
      body: LayoutBuilder(
        builder: (context, c) {
          final landscape = c.maxWidth > c.maxHeight;
          final bgAsset =
              landscape ? kNoWifiBgLandscape : kNoWifiBgPortrait;
          final buttonWidth = landscape
              ? (c.maxWidth * 0.28).clamp(220.0, 420.0)
              : (c.maxWidth * 0.55).clamp(200.0, 360.0);
          // The artwork's central panel ends roughly at ~60% height in
          // portrait and ~80% in landscape — sit the button just below it.
          final buttonBottom = landscape
              ? c.maxHeight * 0.04
              : c.maxHeight * 0.20;
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(bgAsset, fit: BoxFit.cover),
              Positioned(
                left: 0,
                right: 0,
                bottom: buttonBottom,
                child: Center(
                  child: _RetryPlate(
                    width: buttonWidth.toDouble(),
                    busy: _busy,
                    press: _press,
                    onTap: _retry,
                  ),
                ),
              ),
              SafeArea(
                child: Align(
                  alignment: landscape
                      ? Alignment.topCenter
                      : Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: landscape ? 12 : 16,
                    ),
                    child: AnimatedOpacity(
                      opacity: _hint ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 250),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          child: Text(
                            'Still no internet — please try again.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
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

class _RetryPlate extends StatelessWidget {
  final double width;
  final bool busy;
  final AnimationController press;
  final VoidCallback onTap;

  const _RetryPlate({
    required this.width,
    required this.busy,
    required this.press,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: busy ? null : onTap,
      child: AnimatedBuilder(
        animation: press,
        builder: (_, child) {
          final scale = 1.0 - 0.05 * press.value;
          return Transform.scale(scale: scale, child: child);
        },
        child: SizedBox(
          width: width,
          child: AspectRatio(
            aspectRatio: 3.6,
            child: Stack(
              alignment: Alignment.center,
              fit: StackFit.expand,
              children: [
                Image.asset(kNoWifiButton, fit: BoxFit.contain),
                if (busy)
                  const Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Color(0xFF2A150A)),
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
