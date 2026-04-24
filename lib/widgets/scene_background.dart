import 'package:flutter/material.dart';

import '../game/constants.dart';

class SceneBackground extends StatelessWidget {
  final Widget fieldOverlay;

  const SceneBackground({super.key, required this.fieldOverlay});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const aspect = kCols / kRows;
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;

        double fieldW = maxW * 0.78;
        double fieldH = fieldW / aspect;
        final maxFieldH = maxH * 0.78;
        if (fieldH > maxFieldH) {
          fieldH = maxFieldH;
          fieldW = fieldH * aspect;
        }

        final wallW = fieldW * 0.12;
        final baseW = fieldW + wallW * 2.4;
        final baseH = baseW * 0.6;

        final centerX = maxW / 2;
        final fieldTop = (maxH - fieldH - baseH * 0.25) / 2;
        final fieldLeft = centerX - fieldW / 2;
        final baseTop = fieldTop + fieldH - baseH * 0.35;

        return Stack(
          children: [
            Positioned.fill(
              child: Image.asset(kBgAsset, fit: BoxFit.cover),
            ),
            Positioned(
              left: centerX - baseW / 2,
              top: baseTop,
              width: baseW,
              height: baseH,
              child: Image.asset(kBaseAsset, fit: BoxFit.fill),
            ),
            Positioned(
              left: fieldLeft - wallW * 0.85,
              top: fieldTop,
              width: wallW,
              height: fieldH,
              child: Image.asset(kLeftWallAsset, fit: BoxFit.fill),
            ),
            Positioned(
              left: fieldLeft + fieldW - wallW * 0.15,
              top: fieldTop,
              width: wallW,
              height: fieldH,
              child: Image.asset(kRightWallAsset, fit: BoxFit.fill),
            ),
            Positioned(
              left: fieldLeft,
              top: fieldTop,
              width: fieldW,
              height: fieldH,
              child: Image.asset(kGridAsset, fit: BoxFit.fill),
            ),
            Positioned(
              left: fieldLeft,
              top: fieldTop,
              width: fieldW,
              height: fieldH,
              child: fieldOverlay,
            ),
          ],
        );
      },
    );
  }
}
