import 'constants.dart';
import 'piece.dart';

class Board {
  final List<List<int?>> cells;

  Board()
      : cells = List.generate(
          kRows,
          (_) => List<int?>.filled(kCols, null),
        );

  int? at(int r, int c) => cells[r][c];

  bool canPlace(Piece piece) {
    for (final cell in piece.occupiedCells()) {
      if (cell.r < 0) continue;
      if (cell.r >= kRows) return false;
      if (cell.c < 0 || cell.c >= kCols) return false;
      if (cells[cell.r][cell.c] != null) return false;
    }
    return true;
  }

  void merge(Piece piece) {
    for (final cell in piece.occupiedCells()) {
      if (cell.r < 0 || cell.r >= kRows) continue;
      if (cell.c < 0 || cell.c >= kCols) continue;
      cells[cell.r][cell.c] = cell.tex;
    }
  }

  int clearLines() {
    int cleared = 0;
    for (int r = kRows - 1; r >= 0; r--) {
      bool full = true;
      for (int c = 0; c < kCols; c++) {
        if (cells[r][c] == null) {
          full = false;
          break;
        }
      }
      if (full) {
        cells.removeAt(r);
        cells.insert(0, List<int?>.filled(kCols, null));
        cleared++;
        r++;
      }
    }
    return cleared;
  }

  void reset() {
    for (int r = 0; r < kRows; r++) {
      for (int c = 0; c < kCols; c++) {
        cells[r][c] = null;
      }
    }
  }
}
