import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genes.dart';
import 'package:splice/src/genome/genome.dart';

/// Standing in a swarm must always be a losing trade.
///
/// Lifesteal is applied per hit and hit count scales with how many enemies
/// surround the player, while incoming contact damage is gated by
/// invulnerability frames. Uncapped, that makes a dense crowd *safer* than an
/// empty field and the player unkillable.
World swarmedPlayer({required int leechStacks}) {
  final world = World(21);
  world.abilities.clear();
  // Worst case: a wide aura, which hits everything nearby every activation.
  world.addAbility(Genome(
    vector: Vector.aura,
    payload: Payload.kinetic,
    trigger: Trigger.timer,
    riders: {Rider.leech: leechStacks, Rider.reach: 6, Rider.amplify: 8},
  ));
  return world;
}

void packSwarm(World world) {
  for (var i = 0; i < 90; i++) {
    final e = world.enemyPool.obtain();
    if (e == null) break;
    // Pressed right against the player, which is the situation that used to
    // be survivable indefinitely.
    e.spawn(enemyDefs['crawler']!, world.px + (i % 9) * 3.0 - 12,
        world.py + (i ~/ 9) * 3.0 - 12, 0, 30.0);
  }
}

void main() {
  test('a heavily leeching build still dies standing in a crowd', () {
    final world = swarmedPlayer(leechStacks: 400);
    world.hp = world.maxHp;

    var died = false;
    for (var i = 0; i < 60 * 60 && !died; i++) {
      world.pendingLevelUps = 0;
      if (i % 30 == 0) packSwarm(world);
      world.update(1 / 60);
      died = world.gameOver;
    }
    expect(died, isTrue,
        reason: 'the player out-healed a packed swarm for a full minute');
  });

  test('leech is capped per second, not per hit', () {
    final world = swarmedPlayer(leechStacks: 400);
    packSwarm(world);
    world.hp = 1.0;
    final cap = world.maxHp *
        (World.leechBaseCap + 0.35 * World.leechCapPerStack);

    // One second of the densest possible contact.
    for (var i = 0; i < 60; i++) {
      world.pendingLevelUps = 0;
      world.gameOver = false;
      world.update(1 / 60);
    }
    // Healing within the window cannot exceed the cap, with a little slack for
    // health pickups a kill may have dropped.
    expect(world.hp - 1.0, lessThan(cap + world.maxHp * 0.15),
        reason: 'healed ${world.hp - 1.0} in one second against a cap of $cap');
  });

  test('leech still meaningfully sustains against light pressure', () {
    final world = swarmedPlayer(leechStacks: 12);
    world.hp = world.maxHp * 0.5;
    // A handful of enemies, not a wall of them.
    for (var i = 0; i < 6; i++) {
      final e = world.enemyPool.obtain();
      if (e == null) break;
      e.spawn(enemyDefs['mote']!, world.px + 40.0 + i * 6, world.py, 0, 2.0);
    }
    final before = world.hp;
    for (var i = 0; i < 180; i++) {
      world.pendingLevelUps = 0;
      world.gameOver = false;
      world.update(1 / 60);
    }
    expect(world.hp, greaterThan(before),
        reason: 'leech should still be worth taking');
  });
}
