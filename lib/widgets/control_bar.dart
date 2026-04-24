import 'package:flutter/material.dart';

import '../app_theme.dart';

class ControlBar extends StatelessWidget {
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onRotate;
  final ValueChanged<bool> onSoftDrop;
  final VoidCallback onHardDrop;

  const ControlBar({
    super.key,
    required this.onLeft,
    required this.onRight,
    required this.onRotate,
    required this.onSoftDrop,
    required this.onHardDrop,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
        child: Row(
          children: [
            Expanded(
              child: _HoldButton(
                icon: Icons.arrow_back_rounded,
                onTap: onLeft,
                hold: true,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _HoldButton(
                icon: Icons.rotate_right_rounded,
                onTap: onRotate,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _PressButton(
                icon: Icons.arrow_downward_rounded,
                onPressed: () => onSoftDrop(true),
                onReleased: () => onSoftDrop(false),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _HoldButton(
                icon: Icons.vertical_align_bottom_rounded,
                onTap: onHardDrop,
                primary: true,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _HoldButton(
                icon: Icons.arrow_forward_rounded,
                onTap: onRight,
                hold: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HoldButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;
  final bool hold;

  const _HoldButton({
    required this.icon,
    required this.onTap,
    this.primary = false,
    this.hold = false,
  });

  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> {
  bool _pressed = false;

  void _startHold() {
    widget.onTap();
    if (!widget.hold) return;
    setState(() => _pressed = true);
    Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 110));
      if (!mounted || !_pressed) return false;
      widget.onTap();
      return true;
    });
  }

  void _endHold() {
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    return _ButtonSkin(
      icon: widget.icon,
      primary: widget.primary,
      pressed: _pressed,
      onTapDown: (_) => _startHold(),
      onTapUp: (_) => _endHold(),
      onTapCancel: _endHold,
    );
  }
}

class _PressButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final VoidCallback onReleased;

  const _PressButton({
    required this.icon,
    required this.onPressed,
    required this.onReleased,
  });

  @override
  State<_PressButton> createState() => _PressButtonState();
}

class _PressButtonState extends State<_PressButton> {
  bool _pressed = false;

  void _press() {
    if (_pressed) return;
    setState(() => _pressed = true);
    widget.onPressed();
  }

  void _release() {
    if (!_pressed) return;
    setState(() => _pressed = false);
    widget.onReleased();
  }

  @override
  void dispose() {
    if (_pressed) widget.onReleased();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ButtonSkin(
      icon: widget.icon,
      primary: false,
      pressed: _pressed,
      onTapDown: (_) => _press(),
      onTapUp: (_) => _release(),
      onTapCancel: _release,
    );
  }
}

class _ButtonSkin extends StatelessWidget {
  final IconData icon;
  final bool primary;
  final bool pressed;
  final ValueChanged<TapDownDetails> onTapDown;
  final ValueChanged<TapUpDetails> onTapUp;
  final VoidCallback onTapCancel;

  const _ButtonSkin({
    required this.icon,
    required this.primary,
    required this.pressed,
    required this.onTapDown,
    required this.onTapUp,
    required this.onTapCancel,
  });

  @override
  Widget build(BuildContext context) {
    final color = primary ? kAccent : Colors.white;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: onTapDown,
      onTapUp: onTapUp,
      onTapCancel: onTapCancel,
      child: Container(
        height: 58,
        decoration: BoxDecoration(
          color: primary
              ? kAccent.withValues(alpha: pressed ? 0.45 : 0.25)
              : Colors.white.withValues(alpha: pressed ? 0.18 : 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: (primary ? kAccent : Colors.white).withValues(alpha: 0.55),
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: color, size: 26),
      ),
    );
  }
}
