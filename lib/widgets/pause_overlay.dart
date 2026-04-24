import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'menu_button.dart';

class PauseOverlay extends StatelessWidget {
  final VoidCallback onResume;
  final VoidCallback onMenu;

  const PauseOverlay({
    super.key,
    required this.onResume,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: DecoratedBox(
        decoration:
            BoxDecoration(color: Colors.black.withValues(alpha: 0.72)),
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 28),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            decoration: panelDecoration(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'PAUSED',
                  style: TextStyle(
                    color: kAccent,
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: MenuButton(
                    label: 'RESUME',
                    icon: Icons.play_arrow_rounded,
                    primary: true,
                    onTap: onResume,
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
}
