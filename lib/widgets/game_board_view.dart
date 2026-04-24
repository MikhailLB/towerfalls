import 'package:flutter/material.dart';

import '../game/constants.dart';
import '../game/game_controller.dart';

class GameBoardView extends StatelessWidget {
  final GameController controller;

  const GameBoardView({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellW = constraints.maxWidth / kCols;
        final cellH = constraints.maxHeight / kRows;

        final children = <Widget>[];

        for (int r = 0; r < kRows; r++) {
          for (int c = 0; c < kCols; c++) {
            final tex = controller.board.at(r, c);
            if (tex != null) {
              children.add(_cell(
                left: c * cellW,
                top: r * cellH,
                cellW: cellW,
                cellH: cellH,
                tex: tex,
              ));
            }
          }
        }

        final piece = controller.current;
        if (piece != null) {
          final dy = controller.renderFallProgress * cellH;
          for (final cell in piece.occupiedCells()) {
            if (cell.r < -1 || cell.r >= kRows) continue;
            if (cell.c < 0 || cell.c >= kCols) continue;
            children.add(_cell(
              left: cell.c * cellW,
              top: cell.r * cellH + dy,
              cellW: cellW,
              cellH: cellH,
              tex: cell.tex,
            ));
          }
        }

        return ClipRect(child: Stack(children: children));
      },
    );
  }

  Widget _cell({
    required double left,
    required double top,
    required double cellW,
    required double cellH,
    required int tex,
  }) {
    return Positioned(
      left: left,
      top: top,
      width: cellW,
      height: cellH,
      child: Image.asset(
        blockAssetPath(tex),
        fit: BoxFit.fill,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
