import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/rng.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genes.dart';
import 'package:splice/src/genome/genome.dart';

/// Simulation cost under load.
///
/// This measures the update step only — collision, steering, separation,
/// ability resolution — not rendering, which is one batched draw call.
/// A 60fps frame is 16.7ms total; the simulation needs to fit well inside that
/// with room for Flutter's own pipeline, so the budget here is deliberately
/// tight.
///
/// Numbers are from a desktop test host and will be slower on a phone, so the
/// thresholds are set with a wide margin rather than at the real frame budget.
void main() {
  /// Fills a world with a heavy but reachable late-run state.
  World heavyWorld({required int enemies, required int abilityCount}) {
    final world = World(1234);
    final rng = Rng(99);

    while (world.abilities.length < abilityCount) {
      // Force a spread of vectors so every code path in the runtime is live,
      // including the persistent and instant ones.
      world.addAbility(Genome(
        vector: Vector.values[world.abilities.length % Vector.values.length],
        payload: Payload.values[world.abilities.length % Payload.values.length],
        trigger: Trigger.timer,
        riders: {Rider.split: 3, Rider.amplify: 4, Rider.pierce: 2, Rider.reach: 2},
        generation: 8,
      ));
    }

    world.viewHalfWidth = 220;
    world.viewHalfHeight = 400;

    // Pack the swarm in tight around the player, which is the worst case for
    // both separation and collision.
    for (var i = 0; i < enemies; i++) {
      final e = world.enemyPool.obtain();
      if (e == null) break;
      final def = enemyDefsList[i % enemyDefsList.length];
      e.spawn(def, rng.range(-260, 260), rng.range(-420, 420), i % 4, 4.0);
    }
    return world;
  }

  double measure(World world, int frames) {
    final sw = Stopwatch()..start();
    for (var i = 0; i < frames; i++) {
      // Level-ups would halt the simulation, so drain them.
      world.pendingLevelUps = 0;
      world.hp = world.maxHp;
      world.gameOver = false;
      world.inputX = (i % 120 < 60) ? 1.0 : -1.0;
      world.update(1 / 60);
    }
    sw.stop();
    return sw.elapsedMicroseconds / frames / 1000.0; // ms per frame
  }

  test('sustains a heavy swarm inside the frame budget', () {
    final world = heavyWorld(enemies: 400, abilityCount: 6);
    measure(world, 60); // warm up the JIT before timing
    final ms = measure(world, 600);

    // ignore: avoid_print
    print('400 enemies, 6 abilities: ${ms.toStringAsFixed(3)} ms/frame '
        '(${world.liveEnemies} live, ${world.shotPool.liveCount} shots, '
        '${world.particlePool.liveCount} particles)');

    expect(ms, lessThan(4.0),
        reason: 'simulation must leave most of the 16.7ms frame to rendering');
  });

  test('degrades gracefully at the pool ceiling', () {
    final world = heavyWorld(enemies: 700, abilityCount: 6);
    measure(world, 60);
    final ms = measure(world, 300);

    // ignore: avoid_print
    print('700 enemies (pool cap): ${ms.toStringAsFixed(3)} ms/frame');

    expect(ms, lessThan(8.0));
  });

  test('pools never exceed their capacity', () {
    final world = heavyWorld(enemies: 700, abilityCount: 6);
    for (var i = 0; i < 1200; i++) {
      world.pendingLevelUps = 0;
      world.hp = world.maxHp;
      world.gameOver = false;
      world.update(1 / 60);
    }
    expect(world.enemyPool.liveCount, lessThanOrEqualTo(world.enemyPool.capacity));
    expect(world.shotPool.liveCount, lessThanOrEqualTo(world.shotPool.capacity));
    expect(world.particlePool.liveCount, lessThanOrEqualTo(world.particlePool.capacity));
    expect(world.pickupPool.liveCount, lessThanOrEqualTo(world.pickupPool.capacity));
  });

  test('a long run stays stable and finite', () {
    final world = World(7);
    for (var i = 0; i < 6; i++) {
      world.addAbility(Genome.wild(Rng(i), power: 6));
    }
    // Twelve simulated minutes at 60fps.
    for (var i = 0; i < 60 * 60 * 12; i++) {
      world.pendingLevelUps = 0;
      world.hp = world.maxHp;
      world.gameOver = false;
      world.inputX = (i % 200 < 100) ? 0.7 : -0.7;
      world.inputY = (i % 300 < 150) ? 0.7 : -0.7;
      world.update(1 / 60);
    }
    expect(world.px.isFinite, isTrue);
    expect(world.py.isFinite, isTrue);
    expect(world.kills, greaterThan(0));
    for (final r in world.resistance.values) {
      expect(r, inInclusiveRange(0.0, World.maxResistance));
    }
    // ignore: avoid_print
    print('12 simulated minutes: level ${world.level}, ${world.kills} kills, '
        'resistances ${world.resistance.entries.where((e) => e.value > 0.01).map((e) => '${e.key.name}=${(e.value * 100).round()}%').join(' ')}');
  });
}

final enemyDefsList = enemyDefs.values.toList();
