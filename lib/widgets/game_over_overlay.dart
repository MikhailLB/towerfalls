import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'menu_button.dart';

class GameOverOverlay extends StatelessWidget {
  final int score;
  final int best;
  final VoidCallback onRetry;
  final VoidCallback onMenu;

  const GameOverOverlay({
    super.key,
    required this.score,
    required this.best,
    required this.onRetry,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final isNewBest = score >= best && score > 0;
    return Positioned.fill(
      child: DecoratedBox(
        decoration:
            BoxDecoration(color: Colors.black.withValues(alpha: 0.82)),
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 28),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            decoration: panelDecoration(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'TOWER FELL',
                  style: TextStyle(
                    color: kAccent,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 18),
                _stat('SCORE', '$score', highlight: isNewBest),
                const SizedBox(height: 8),
                _stat('BEST', '$best'),
                if (isNewBest) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'NEW RECORD!',
                    style: TextStyle(
                      color: kAccent,
                      fontSize: 14,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: MenuButton(
                    label: 'RETRY',
                    icon: Icons.replay_rounded,
                    primary: true,
                    onTap: onRetry,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: MenuButton(
                    label: 'MAIN MENU',
                    icon: Icons.home_rounded,
                    onTap: onMenu,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value, {bool highlight = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 14,
            letterSpacing: 3,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: highlight ? kAccent : Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}
