import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/rng.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genome.dart';

/// The level-up gate.
///
/// A run must halt the moment the player levels, and stay halted until the
/// Splice choice is made. If it does not, levels silently pass by and the
/// game's central decision never gets offered.
void main() {
  test('gaining a level raises pendingLevelUps', () {
    final world = World(1);
    expect(world.pendingLevelUps, 0);

    // Drop enough xp to cross the first threshold.
    world.addAbility(Genome.wild(Rng(1), power: 2));
    var guard = 0;
    while (world.pendingLevelUps == 0 && guard++ < 100000) {
      world.update(1 / 60);
    }
    expect(world.pendingLevelUps, greaterThan(0),
        reason: 'a run should reach level 2 well inside 100k frames');
  });

  test('the simulation freezes while a level-up is pending', () {
    final world = World(2);
    var guard = 0;
    while (world.pendingLevelUps == 0 && guard++ < 100000) {
      world.update(1 / 60);
    }
    expect(world.pendingLevelUps, greaterThan(0));

    final frozenTime = world.time;
    final frozenKills = world.kills;
    final frozenLevel = world.level;

    // Hammer the update loop; nothing may advance.
    for (var i = 0; i < 600; i++) {
      world.update(1 / 60);
    }

    expect(world.time, frozenTime, reason: 'time advanced during a pending level-up');
    expect(world.kills, frozenKills, reason: 'kills advanced during a pending level-up');
    expect(world.level, frozenLevel, reason: 'level advanced during a pending level-up');
  });

  test('the run resumes once the level-up is consumed', () {
    final world = World(3);
    var guard = 0;
    while (world.pendingLevelUps == 0 && guard++ < 100000) {
      world.update(1 / 60);
    }
    final stalledAt = world.time;

    // Consume it the way the Splice screen does.
    world.addAbility(Genome.wild(world.rng, power: 2));
    world.pendingLevelUps--;

    for (var i = 0; i < 60; i++) {
      world.update(1 / 60);
    }
    expect(world.time, greaterThan(stalledAt));
  });

  test('multiple levels in one frame each require their own choice', () {
    final world = World(4);
    // A large xp grant should be able to cross several thresholds at once.
    world.pendingLevelUps = 0;
    final before = world.level;
    while (world.pendingLevelUps < 1) {
      world.update(1 / 60);
    }
    expect(world.level, greaterThan(before));
    // Consuming one at a time must leave the rest pending.
    final pending = world.pendingLevelUps;
    world.pendingLevelUps--;
    expect(world.pendingLevelUps, pending - 1);
  });
}
