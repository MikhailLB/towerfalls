import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../game/constants.dart';
import '../config/runtime_brand.dart';
import '../services/network_radar.dart';
import '../services/pulse_dispatch.dart';
import '../services/runtime_cache.dart';
import 'browser_shell.dart';

/// Custom permission prompt shown before opening the WebView. The screen
/// uses a branded background video and two engraved "Accept" / "Skip"
/// plates rendered with custom painters so we don't depend on opaque PNGs.
class NotifyOfferScreen extends StatefulWidget {
  final RuntimeCache cache;
  final PulseDispatch pulse;
  final NetworkRadar radar;
  final String destination;
  final Future<void> Function(String token)? onPushTokenReady;

  const NotifyOfferScreen({
    super.key,
    required this.cache,
    required this.pulse,
    required this.radar,
    required this.destination,
    this.onPushTokenReady,
  });

  @override
  State<NotifyOfferScreen> createState() => _NotifyOfferScreenState();
}

class _NotifyOfferScreenState extends State<NotifyOfferScreen>
    with TickerProviderStateMixin {
  VideoPlayerController? _video;
  Orientation? _videoOrientation;
  bool _videoLoading = false;
  bool _videoFailed = false;
  bool _busy = false;

  late final AnimationController _shimmer;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat(reverse: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final orientation = MediaQuery.of(context).orientation;
    if (!_videoLoading && _videoOrientation != orientation) {
      _loadVideo(orientation);
    }
  }

  Future<void> _loadVideo(Orientation orientation) async {
    _videoLoading = true;
    final asset = orientation == Orientation.landscape
        ? kNotifyVideoLandscape
        : kNotifyVideoPortrait;

    final previous = _video;
    final controller = VideoPlayerController.asset(asset);
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
        _videoOrientation = orientation;
        _videoFailed = false;
      });
      await previous?.dispose();
    } catch (e, st) {
      debugPrint('Notify video failed ($asset): $e\n$st');
      await controller.dispose();
      if (mounted) {
        setState(() {
          _videoOrientation = orientation;
          _videoFailed = true;
        });
      }
    } finally {
      _videoLoading = false;
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    _shimmer.dispose();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final granted = await widget.pulse.askConsent();
      if (granted) {
        final token = await widget.pulse.refreshTokenAfterConsent(
          notify: false,
        );
        if (token != null && token.isNotEmpty) {
          await widget.onPushTokenReady?.call(token);
        }
      }
      if (!granted) {
        await _registerCooldown();
      }
      _openShell();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _skip() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _registerCooldown();
    _openShell();
  }

  Future<void> _registerCooldown() async {
    final until = (DateTime.now().millisecondsSinceEpoch ~/ 1000) +
        RuntimeBrand.notifyCooldownSeconds;
    await widget.cache.writePushCooldownUntil(until);
  }

  void _openShell() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => BrowserShell(
          destination: widget.destination,
          cache: widget.cache,
          pulse: widget.pulse,
          radar: widget.radar,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final ready = video != null && video.value.isInitialized;
    return Scaffold(
      backgroundColor: const Color(0xFF050912),
      body: LayoutBuilder(
        builder: (context, c) {
          final landscape = c.maxWidth > c.maxHeight;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (ready)
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
                const ColoredBox(color: Color(0xFF050912)),
              if (landscape)
                _landscapeLayout(c)
              else
                _portraitLayout(c),
            ],
          );
        },
      ),
    );
  }

  Widget _portraitLayout(BoxConstraints c) {
    final width = c.maxWidth;
    final buttonWidth = width * 0.78;
    final bottomGap = c.maxHeight * 0.07;
    return SafeArea(
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomGap,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _BonusButton(
                  width: buttonWidth,
                  label: 'ACCEPT',
                  busy: _busy,
                  enabled: !_busy,
                  shimmer: _shimmer,
                  pulse: _pulse,
                  variant: _ButtonVariant.gold,
                  onTap: _accept,
                ),
                SizedBox(height: c.maxHeight * 0.022),
                _BonusButton(
                  width: buttonWidth,
                  label: 'SKIP',
                  busy: false,
                  enabled: !_busy,
                  shimmer: _shimmer,
                  pulse: _pulse,
                  variant: _ButtonVariant.slate,
                  onTap: _skip,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _landscapeLayout(BoxConstraints c) {
    final buttonWidth = (c.maxWidth * 0.28).clamp(220.0, 380.0);
    final bottomGap = c.maxHeight * 0.05;
    return SafeArea(
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomGap,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _BonusButton(
                  width: buttonWidth.toDouble(),
                  label: 'ACCEPT',
                  busy: _busy,
                  enabled: !_busy,
                  shimmer: _shimmer,
                  pulse: _pulse,
                  variant: _ButtonVariant.gold,
                  onTap: _accept,
                  aspectRatio: 5.6,
                ),
                SizedBox(height: c.maxHeight * 0.025),
                _BonusButton(
                  width: buttonWidth.toDouble(),
                  label: 'SKIP',
                  busy: false,
                  enabled: !_busy,
                  shimmer: _shimmer,
                  pulse: _pulse,
                  variant: _ButtonVariant.slate,
                  onTap: _skip,
                  aspectRatio: 5.6,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _ButtonVariant { gold, slate }

class _ButtonPalette {
  final Color innerStart;
  final Color innerEnd;
  final Color rimDark;
  final Color rimLight;
  final Color highlight;
  final Color glow;
  final Color textColor;
  final Color textStroke;

  const _ButtonPalette({
    required this.innerStart,
    required this.innerEnd,
    required this.rimDark,
    required this.rimLight,
    required this.highlight,
    required this.glow,
    required this.textColor,
    required this.textStroke,
  });

  factory _ButtonPalette.of(_ButtonVariant v) {
    switch (v) {
      case _ButtonVariant.gold:
        return const _ButtonPalette(
          innerStart: Color(0xFFFFD24A),
          innerEnd: Color(0xFFE0681A),
          rimDark: Color(0xFF7A2A06),
          rimLight: Color(0xFFFFE7A0),
          highlight: Color(0xFFFFF6CC),
          glow: Color(0xFFFFB74D),
          textColor: Color(0xFFFFFFFF),
          textStroke: Color(0xFF6E1F00),
        );
      case _ButtonVariant.slate:
        return const _ButtonPalette(
          innerStart: Color(0xFF3C4860),
          innerEnd: Color(0xFF1F2738),
          rimDark: Color(0xFF0B0F1A),
          rimLight: Color(0xFFD5A24A),
          highlight: Color(0xFFB8C4DA),
          glow: Color(0xFF6B7B98),
          textColor: Color(0xFFFFEAB8),
          textStroke: Color(0xFF1A1208),
        );
    }
  }
}

class _BonusButton extends StatefulWidget {
  final double width;
  final String label;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  final _ButtonVariant variant;
  final AnimationController shimmer;
  final AnimationController pulse;
  final double aspectRatio;

  const _BonusButton({
    required this.width,
    required this.label,
    required this.busy,
    required this.enabled,
    required this.onTap,
    required this.variant,
    required this.shimmer,
    required this.pulse,
    this.aspectRatio = 4.4,
  });

  @override
  State<_BonusButton> createState() => _BonusButtonState();
}

class _BonusButtonState extends State<_BonusButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 110),
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  bool get _interactive => widget.enabled && !widget.busy;

  Future<void> _onTap() async {
    if (!_interactive) return;
    await _press.forward();
    await _press.reverse();
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final palette = _ButtonPalette.of(widget.variant);
    final plateHeight = widget.width / widget.aspectRatio;
    final fontSize = (plateHeight * 0.46).clamp(14.0, 30.0);
    final isHero = widget.variant == _ButtonVariant.gold;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      child: AnimatedBuilder(
        animation: Listenable.merge([_press, widget.shimmer, widget.pulse]),
        builder: (_, _) {
          final scale = 1.0 - 0.04 * _press.value;
          // Gentle pulse only on the hero (Accept) button.
          final pulseT = isHero ? widget.pulse.value : 0.0;
          return Opacity(
            opacity: _interactive ? 1.0 : 0.55,
            child: Transform.scale(
              scale: scale,
              child: SizedBox(
                width: widget.width,
                child: AspectRatio(
                  aspectRatio: widget.aspectRatio,
                  child: CustomPaint(
                    painter: _BonusButtonPainter(
                      palette: palette,
                      shimmer: widget.shimmer.value,
                      pulse: pulseT,
                      pressed: _press.value,
                      hero: isHero,
                    ),
                    child: Center(
                      child: widget.busy
                          ? SizedBox(
                              width: fontSize + 6,
                              height: fontSize + 6,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  palette.textColor,
                                ),
                              ),
                            )
                          : _StrokedLabel(
                              label: widget.label,
                              fontSize: fontSize,
                              color: palette.textColor,
                              stroke: palette.textStroke,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Filled label with a thicker contrasting outline. The CustomPaint stack
/// (background plate) supplies the bevel / glow, this widget only handles
/// the legible "stickered" text on top.
class _StrokedLabel extends StatelessWidget {
  final String label;
  final double fontSize;
  final Color color;
  final Color stroke;

  const _StrokedLabel({
    required this.label,
    required this.fontSize,
    required this.color,
    required this.stroke,
  });

  @override
  Widget build(BuildContext context) {
    final outlineWidth = math.max(2.0, fontSize * 0.12);
    return Stack(
      alignment: Alignment.center,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w900,
            letterSpacing: 4,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = outlineWidth
              ..strokeJoin = StrokeJoin.round
              ..color = stroke,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: FontWeight.w900,
            letterSpacing: 4,
            shadows: const [
              Shadow(
                color: Color(0x66000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BonusButtonPainter extends CustomPainter {
  final _ButtonPalette palette;
  final double shimmer;
  final double pulse;
  final double pressed;
  final bool hero;

  _BonusButtonPainter({
    required this.palette,
    required this.shimmer,
    required this.pulse,
    required this.pressed,
    required this.hero,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cornerRadius = h * 0.45;

    final outerRect = Rect.fromLTWH(0, 0, w, h);
    final outerRRect = RRect.fromRectAndRadius(
      outerRect.deflate(2),
      Radius.circular(cornerRadius),
    );
    final innerRRect = RRect.fromRectAndRadius(
      outerRect.deflate(h * 0.13),
      Radius.circular(cornerRadius * 0.85),
    );

    // Outer pulsing glow (only for the hero button so it draws the eye).
    if (hero) {
      final glowAlpha = 0.30 + 0.25 * pulse;
      final glowPaint = Paint()
        ..color = palette.glow.withValues(alpha: glowAlpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.outer, 16 + 6 * pulse);
      canvas.drawRRect(outerRRect, glowPaint);
    }

    // Drop shadow under the button.
    canvas.drawRRect(
      outerRRect.shift(Offset(0, h * 0.10)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    // Outer rim — vertical metallic gradient from light to dark.
    canvas.drawRRect(
      outerRRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [palette.rimLight, palette.rimDark],
        ).createShader(outerRect),
    );

    // Inner panel.
    canvas.drawRRect(
      innerRRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [palette.innerStart, palette.innerEnd],
        ).createShader(outerRect),
    );

    // Top inner highlight (glossy bevel on the upper half).
    canvas.save();
    canvas.clipRRect(innerRRect);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h * 0.55),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.highlight.withValues(alpha: 0.55),
            palette.highlight.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(0, 0, w, h * 0.55)),
    );

    // Animated diagonal shimmer sweep.
    final shimmerPos = (shimmer * 1.6) - 0.3;
    final cx = w * shimmerPos;
    canvas.drawRect(
      Rect.fromLTWH(-w, -h, w * 3, h * 3),
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-1, -1),
          end: const Alignment(1, 1),
          colors: [
            Colors.transparent,
            palette.highlight.withValues(alpha: hero ? 0.40 : 0.18),
            Colors.transparent,
          ],
          stops: const [0.46, 0.5, 0.54],
        ).createShader(
          Rect.fromCenter(
            center: Offset(cx, h * 0.5),
            width: w * 1.4,
            height: h,
          ),
        ),
    );
    canvas.restore();

    // Inner stroke: gives the engraved feel where panel meets rim.
    canvas.drawRRect(
      innerRRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.2, h * 0.025)
        ..color = palette.rimDark.withValues(alpha: 0.85),
    );

    // Outer rim hairline.
    canvas.drawRRect(
      outerRRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, h * 0.018)
        ..color = palette.rimLight.withValues(alpha: 0.75),
    );

    // Press feedback — subtle dark wash inside the panel when pressed.
    if (pressed > 0) {
      canvas.save();
      canvas.clipRRect(innerRRect);
      canvas.drawColor(
        Colors.black.withValues(alpha: 0.12 * pressed),
        BlendMode.srcOver,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _BonusButtonPainter old) =>
      old.shimmer != shimmer ||
      old.pulse != pulse ||
      old.pressed != pressed ||
      old.hero != hero ||
      old.palette != palette;
}
