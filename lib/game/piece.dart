import 'dart:math';

import 'constants.dart';
import 'tetromino.dart';

class Piece {
  final TetrominoDef def;
  int rotation;
  int row;
  int col;
  final List<List<int>> blockTextures;

  Piece({
    required this.def,
    required this.rotation,
    required this.row,
    required this.col,
    required this.blockTextures,
  });

  List<List<int>> get shape => def.rotations[rotation % def.rotations.length];

  int get size => shape.length;

  Piece copyWith({int? rotation, int? row, int? col}) => Piece(
        def: def,
        rotation: rotation ?? this.rotation,
        row: row ?? this.row,
        col: col ?? this.col,
        blockTextures: blockTextures,
      );

  static Piece spawn(TetrominoDef def, Random random) {
    final size = def.rotations.first.length;
    final textures = List.generate(
      size,
      (_) => List.generate(
        size,
        (_) => kBlockIndices[random.nextInt(kBlockIndices.length)],
      ),
    );
    final startCol = ((kCols - size) / 2).floor();
    return Piece(
      def: def,
      rotation: 0,
      row: 0,
      col: startCol,
      blockTextures: textures,
    );
  }

  Iterable<({int r, int c, int tex})> occupiedCells() sync* {
    final s = shape;
    for (int r = 0; r < s.length; r++) {
      for (int c = 0; c < s[r].length; c++) {
        if (s[r][c] == 1) {
          yield (r: row + r, c: col + c, tex: blockTextures[r][c]);
        }
      }
    }
  }
}
