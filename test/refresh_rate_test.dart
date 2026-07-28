import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';

/// "The game's physics must perform consistently across different monitor
/// refresh rates" — the portal's requirement, and a real fairness problem
/// besides. Anything applied once per frame is not physics, it is a function
/// of the player's monitor.
///
/// 165 Hz sees 2.75 times as many frames per second as 60 Hz, so a per-frame
/// damping factor decays roughly 2.75 times faster there.
const rates = [60.0, 120.0, 144.0, 165.0];

double _cos(double a) => math.cos(a);
double _sin(double a) => math.sin(a);
double _sqrt(double a) => math.sqrt(a);

World bare(int seed) {
  final world = World(seed);
  world.abilities.clear();
  // Held still: the spawner would otherwise introduce enemies at different
  // moments at each rate and the comparison would mean nothing.
  world.spawningEnabled = false;
  return world;
}

void run(World world, double hz, double seconds) {
  final dt = 1 / hz;
  for (var i = 0; i < (seconds * hz).round(); i++) {
    world.update(dt);
  }
}

void main() {
  test('knockback bleeds off over the same time at any refresh rate', () {
    double travelled(double hz) {
      final world = bare(3);
      final e = world.enemyPool.obtain()!;
      e.spawn(enemyDefs['crawler']!, 600, 0, 0, 100000);
      // Stunned, so steering stays out of it and the only thing acting on the
      // enemy is the knockback decaying.
      e.stunTime = 5;
      e.vx = 500;
      run(world, hz, 0.5);
      return e.x - 600;
    }

    final reference = travelled(60);
    expect(reference, greaterThan(10), reason: 'the impulse must move it');
    for (final hz in rates) {
      expect(travelled(hz), closeTo(reference, reference.abs() * 0.06),
          reason: 'knockback travel differs at ${hz.round()} Hz — enemies '
              'recover from hits faster on a better monitor');
    }
  });

  test('a crowd separates by the same amount at any refresh rate', () {
    // Mean distance from the pack's centre rather than its widest pair. Eight
    // bodies pushing each other apart is a chaotic system, and the extreme of
    // a chaotic system amplifies the integration error that any explicit
    // timestep carries. The average is what a player perceives as "how much
    // the swarm spreads", and it is the thing that must not depend on their
    // monitor.
    double spread(double hz) {
      final world = bare(4);
      final packed = <Enemy>[];
      // A deliberate ring with real overlap: stacking them at nearly the same
      // point is a singular configuration where any difference explodes.
      for (var i = 0; i < 8; i++) {
        final a = i * 0.7853981633974483; // pi / 4
        final e = world.enemyPool.obtain()!;
        e.spawn(enemyDefs['crawler']!, 400 + _cos(a) * 6, _sin(a) * 6, 0, 1e5);
        packed.add(e);
      }
      run(world, hz, 0.5);

      var cx = 0.0, cy = 0.0;
      for (final e in packed) {
        cx += e.x;
        cy += e.y;
      }
      cx /= packed.length;
      cy /= packed.length;
      var total = 0.0;
      for (final e in packed) {
        final dx = e.x - cx, dy = e.y - cy;
        total += _sqrt(dx * dx + dy * dy);
      }
      return total / packed.length;
    }

    final reference = spread(60);
    expect(reference, greaterThan(6), reason: 'the pack must push apart');
    for (final hz in rates) {
      expect(spread(hz), closeTo(reference, reference * 0.1),
          reason: 'the swarm repels differently at ${hz.round()} Hz');
    }
  });

  test('an xp orb reaches the player in the same time at any refresh rate', () {
    double timeToCollect(double hz) {
      final world = bare(5);
      // Inside the magnet's reach, so it homes rather than sitting still.
      world.dropPickupForTest(world.px + 40, world.py, 1);
      final dt = 1 / hz;
      for (var i = 0; i < hz * 4; i++) {
        world.update(dt);
        if (!world.pickups.any((p) => p.alive)) return i * dt;
      }
      return 99;
    }

    final reference = timeToCollect(60);
    expect(reference, lessThan(4), reason: 'it must actually be collected');
    for (final hz in rates) {
      expect(timeToCollect(hz), closeTo(reference, 0.12),
          reason: 'orbs home at a different speed at ${hz.round()} Hz');
    }
  });
}
