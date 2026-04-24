import 'package:flutter/material.dart';

import '../app_theme.dart';

class Hud extends StatelessWidget {
  final int score;
  final int level;
  final int lines;
  final int best;
  final VoidCallback onPause;

  const Hud({
    super.key,
    required this.score,
    required this.level,
    required this.lines,
    required this.best,
    required this.onPause,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _panel(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _stat('SCORE', '$score'),
                    _divider(),
                    _stat('LVL', '$level'),
                    _divider(),
                    _stat('BEST', '$best'),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            _iconButton(Icons.pause_rounded, onPause),
          ],
        ),
      ),
    );
  }

  Widget _panel({required Widget child}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: panelDecoration(radius: 14),
        child: child,
      );

  Widget _stat(String label, String value) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 10,
              letterSpacing: 2,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      );

  Widget _divider() => Container(
        width: 1,
        height: 28,
        color: Colors.white24,
      );

  Widget _iconButton(IconData icon, VoidCallback onTap) => Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: panelDecoration(radius: 14),
            child: Icon(icon, color: kAccent, size: 24),
          ),
        ),
      );
}
