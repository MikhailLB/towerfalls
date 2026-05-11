import 'dart:async';

import 'package:flutter/material.dart';

import '../config/gray_assets.dart';
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
          final bgAsset = landscape
              ? GrayAssets.networkPauseBackgroundLandscape
              : GrayAssets.networkPauseBackgroundPortrait;
          final buttonWidth = landscape
              ? (c.maxWidth * 0.28).clamp(220.0, 420.0)
              : (c.maxWidth * 0.55).clamp(200.0, 360.0);
          final buttonBottom = landscape
              ? c.maxHeight * 0.04
              : c.maxHeight * 0.20;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (bgAsset != null && bgAsset.isNotEmpty)
                Image.asset(bgAsset, fit: BoxFit.cover)
              else
                _DefaultPauseBackground(landscape: landscape),
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
                if (GrayAssets.networkPauseRetryButton != null &&
                    GrayAssets.networkPauseRetryButton!.isNotEmpty)
                  Image.asset(
                    GrayAssets.networkPauseRetryButton!,
                    fit: BoxFit.contain,
                  )
                else
                  _DefaultRetryPlate(busy: busy),
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

/// Default background used when [GrayAssets.networkPauseBackgroundPortrait]
/// / `…Landscape` were not configured. Dark gradient + offline glyph + a
/// hint line so the screen is still informative without bundled artwork.
class _DefaultPauseBackground extends StatelessWidget {
  final bool landscape;
  const _DefaultPauseBackground({required this.landscape});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF111929), Color(0xFF050912)],
            ),
          ),
        ),
        Align(
          alignment: Alignment(0, landscape ? -0.40 : -0.30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.wifi_off,
                size: 64,
                color: Color(0xFFE0E5EE),
              ),
              const SizedBox(height: 14),
              const Text(
                'No internet connection',
                style: TextStyle(
                  color: Color(0xFFE0E5EE),
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Reconnect and tap Retry.',
                style: TextStyle(
                  color: Color(0x99E0E5EE),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Default Material retry button used when
/// [GrayAssets.networkPauseRetryButton] was not configured.
class _DefaultRetryPlate extends StatelessWidget {
  final bool busy;
  const _DefaultRetryPlate({required this.busy});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        height: 56,
        constraints: const BoxConstraints(minWidth: 180),
        padding: const EdgeInsets.symmetric(horizontal: 28),
        decoration: BoxDecoration(
          color: busy ? const Color(0xFFE6B86A) : const Color(0xFFFFC44E),
          borderRadius: BorderRadius.circular(28),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: const Text(
          'RETRY',
          style: TextStyle(
            color: Color(0xFF2A150A),
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }
}
