import 'package:flutter/material.dart';

import '../config/runtime_brand.dart';
import '../services/network_radar.dart';
import '../services/pulse_dispatch.dart';
import '../services/runtime_cache.dart';
import 'browser_shell.dart';

/// Custom permission prompt shown before opening the WebView. Either
/// outcome (allow / skip) hands control over to [BrowserShell] without the
/// system dialog ever blocking the navigation.
class NotifyOfferScreen extends StatefulWidget {
  final RuntimeCache cache;
  final PulseDispatch pulse;
  final NetworkRadar radar;
  final String destination;

  const NotifyOfferScreen({
    super.key,
    required this.cache,
    required this.pulse,
    required this.radar,
    required this.destination,
  });

  @override
  State<NotifyOfferScreen> createState() => _NotifyOfferScreenState();
}

class _NotifyOfferScreenState extends State<NotifyOfferScreen>
    with TickerProviderStateMixin {
  late final AnimationController _glow;
  late final AnimationController _entry;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _entry = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();
  }

  @override
  void dispose() {
    _glow.dispose();
    _entry.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final granted = await widget.pulse.askConsent();
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
    final size = MediaQuery.of(context).size;
    final landscape = size.width > size.height;

    return Scaffold(
      backgroundColor: const Color(0xFF050912),
      body: SafeArea(
        child: FadeTransition(
          opacity: CurvedAnimation(
            parent: _entry,
            curve: Curves.easeOutCubic,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: landscape ? 64 : 28,
              vertical: 24,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _BellBadge(animation: _glow),
                const SizedBox(height: 28),
                const Text(
                  'Stay in the game',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Allow notifications to receive new tower challenges, '
                  'leaderboard updates, and limited-time block packs.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 36),
                _PrimaryAction(
                  label: 'Enable updates',
                  busy: _busy,
                  onTap: _accept,
                ),
                const SizedBox(height: 12),
                _SecondaryAction(
                  label: 'Maybe later',
                  enabled: !_busy,
                  onTap: _skip,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BellBadge extends StatelessWidget {
  final Animation<double> animation;
  const _BellBadge({required this.animation});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (_, _) {
        final t = animation.value;
        return Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [Color(0xFF1F2C57), Color(0xFF0B1224)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFC107).withValues(alpha: 0.25 * t),
                blurRadius: 28 + 10 * t,
                spreadRadius: 1 + 2 * t,
              ),
            ],
            border: Border.all(
              color: const Color(0xFFFFC107).withValues(alpha: 0.55 + 0.2 * t),
              width: 1.4,
            ),
          ),
          child: const Icon(
            Icons.notifications_active_rounded,
            size: 52,
            color: Color(0xFFFFC107),
          ),
        );
      },
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback onTap;

  const _PrimaryAction({
    required this.label,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFFC107), Color(0xFFFF6F00)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFFC107).withValues(alpha: 0.45),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: busy ? null : onTap,
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.black,
                        ),
                      ),
                    )
                  : Text(
                      label,
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.6,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryAction extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  const _SecondaryAction({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: TextButton(
        onPressed: enabled ? onTap : null,
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: Colors.white.withValues(alpha: 0.25),
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.85),
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
          ),
        ),
      ),
    );
  }
}
