import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/ads.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genome.dart';
import 'package:splice/src/core/rng.dart';

/// Revive has to return the player to a survivable situation with their build
/// intact, and it has to be limited — an unlimited continue makes the run
/// timer meaningless.
void main() {
  World deadWorld() {
    final world = World(3);
    world.addAbility(Genome.wild(Rng(2), power: 4));
    // Surround the player, then kill them.
    for (var i = 0; i < 60; i++) {
      final e = world.enemyPool.obtain();
      if (e == null) break;
      e.spawn(enemyDefs['crawler']!, world.px + (i % 10) * 6.0 - 30,
          world.py + (i ~/ 10) * 6.0 - 18, 0, 1.0);
    }
    world.hp = 0.0001;
    world.update(1 / 60);
    // Force the terminal state regardless of contact timing.
    world.hp = 0;
    world.gameOver = true;
    return world;
  }

  test('revive restores health and keeps the build', () {
    final world = deadWorld();
    final abilities = world.abilities.length;
    final level = world.level;
    final time = world.time;

    expect(world.canRevive, isTrue);
    world.revive();

    expect(world.gameOver, isFalse);
    expect(world.hp, greaterThan(0));
    expect(world.abilities.length, abilities, reason: 'abilities must survive');
    expect(world.level, level);
    expect(world.time, time, reason: 'the run continues rather than restarting');
    expect(world.invulnerable, greaterThan(0), reason: 'needs grace on return');
  });

  test('revive clears the enemies that just killed you', () {
    final world = deadWorld();
    world.revive();

    // Nothing may remain inside the clear radius, or the revive is spent
    // instantly on the same wall of enemies.
    for (final e in world.enemies) {
      if (!e.alive) continue;
      final dx = e.x - world.px, dy = e.y - world.py;
      expect(dx * dx + dy * dy, greaterThan(150 * 150),
          reason: 'an enemy survived on top of the player');
    }
  });

  test('revives are limited per run', () {
    final world = deadWorld();
    for (var i = 0; i < World.maxRevives; i++) {
      expect(world.canRevive, isTrue);
      world.revive();
      world.gameOver = true;
    }
    expect(world.canRevive, isFalse, reason: 'revives must run out');
  });

  test('revive is a no-op while alive', () {
    final world = World(9);
    final used = world.revivesUsed;
    world.revive();
    expect(world.revivesUsed, used);
  });

  test('the game-over hook re-arms after a revive', () {
    final world = deadWorld();
    world.markGameOverEmitted();
    expect(world.gameOverEmitted, isTrue);
    world.revive();
    // Otherwise a second death would never surface the end-of-run screen.
    expect(world.gameOverEmitted, isFalse);
  });

  test('a disabled ad service never offers a reward', () async {
    const ads = DisabledAds();
    expect(ads.isReady, isFalse);
    expect(await ads.show(), isFalse);
    // Must be safe to call without any platform plugin present.
    await ads.initialize();
    ads.dispose();
  });
}
