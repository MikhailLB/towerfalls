import 'package:flutter/material.dart';

import '../game/constants.dart';

class LoadingBar extends StatelessWidget {
  final double progress;

  const LoadingBar({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    final asset = progress < 0.34
        ? kEmptyBarAsset
        : progress < 0.75
            ? kAlmostBarAsset
            : kFullBarAsset;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      child: Image.asset(
        asset,
        key: ValueKey(asset),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
