import 'dart:typed_data';

import 'entities.dart';

/// Uniform grid over the area around the player, used for shot-vs-enemy
/// collision and enemy separation.
///
/// Implemented as an intrusive linked list over two Int32Lists rather than a
/// map of buckets, so rebuilding it every frame allocates nothing. The grid
/// follows the player; anything outside its extent is too far away to collide
/// with the player's abilities and is skipped.
class SpatialHash {
  static const double cellSize = 40.0;
  static const int gridDim = 48; // 48 * 40 = 1920 world units of coverage
  static const int _cellCount = gridDim * gridDim;
  static const int _empty = -1;

  final Int32List _head = Int32List(_cellCount);
  final Int32List _next;

  /// World coordinate of the grid's top-left corner, recomputed each rebuild.
  double _originX = 0, _originY = 0;

  SpatialHash(int entityCapacity) : _next = Int32List(entityCapacity);

  /// Clears the grid and re-inserts every live enemy, centred on the player.
  void rebuild(List<Enemy> enemies, double centreX, double centreY) {
    _head.fillRange(0, _cellCount, _empty);
    _originX = centreX - gridDim * cellSize * 0.5;
    _originY = centreY - gridDim * cellSize * 0.5;

    for (var i = 0; i < enemies.length; i++) {
      final e = enemies[i];
      if (!e.alive) continue;
      final cell = _cellOf(e.x, e.y);
      if (cell < 0) continue; // outside the grid; too far to matter this frame
      _next[i] = _head[cell];
      _head[cell] = i;
    }
  }

  int _cellOf(double x, double y) {
    final cx = ((x - _originX) / cellSize).floor();
    final cy = ((y - _originY) / cellSize).floor();
    if (cx < 0 || cy < 0 || cx >= gridDim || cy >= gridDim) return -1;
    return cy * gridDim + cx;
  }

  /// Calls [visit] with the index of every enemy in cells overlapping the
  /// circle at ([x], [y]) with the given [radius].
  ///
  /// Cells are a conservative filter: callers still need an exact distance
  /// check, but only against a handful of candidates instead of the whole swarm.
  void forEachNear(double x, double y, double radius, void Function(int index) visit) {
    final minX = ((x - radius - _originX) / cellSize).floor().clamp(0, gridDim - 1);
    final maxX = ((x + radius - _originX) / cellSize).floor().clamp(0, gridDim - 1);
    final minY = ((y - radius - _originY) / cellSize).floor().clamp(0, gridDim - 1);
    final maxY = ((y + radius - _originY) / cellSize).floor().clamp(0, gridDim - 1);

    for (var cy = minY; cy <= maxY; cy++) {
      final row = cy * gridDim;
      for (var cx = minX; cx <= maxX; cx++) {
        var i = _head[row + cx];
        while (i != _empty) {
          visit(i);
          i = _next[i];
        }
      }
    }
  }
}
