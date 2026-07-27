import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genes.dart';
import 'package:splice/src/genome/genome.dart';

/// Several triggers gate on a condition, not just a cooldown. The HUD needs to
/// know which, or a fully charged ability that cannot fire looks identical to
/// one that is about to — which reads to the player as a broken skill.
World withTrigger(Trigger t) {
  final world = World(31);
  world.abilities.clear();
  world.addAbility(Genome(
    vector: Vector.burst,
    payload: Payload.kinetic,
    trigger: t,
    riders: const {},
  ));
  // Something to shoot, so nothing is gated on an empty field.
  for (var i = 0; i < 8; i++) {
    final e = world.enemyPool.obtain();
    if (e == null) break;
    e.spawn(enemyDefs['crawler']!, 30.0 + i * 4, 0, 0, 500.0);
  }
  return world;
}

void run(World world, {required bool moving, int frames = 90, double hp = 1.0}) {
  for (var i = 0; i < frames; i++) {
    world.pendingLevelUps = 0;
    world.gameOver = false;
    world.hp = world.maxHp * hp;
    world.inputX = moving ? 1.0 : 0.0;
    world.inputY = 0.0;
    world.update(1 / 60);
  }
}

void main() {
  test('a timed ability is never reported as waiting', () {
    final world = withTrigger(Trigger.timer);
    run(world, moving: true);
    expect(world.abilities.first.waiting, isFalse);
  });

  test('While Still is blocked while moving and clears when stopped', () {
    final world = withTrigger(Trigger.onStill);
    run(world, moving: true);
    expect(world.abilities.first.waiting, isTrue,
        reason: 'moving must block a While Still ability');

    run(world, moving: false);
    expect(world.abilities.first.waiting, isFalse,
        reason: 'standing still must release it');
  });

  test('While Moving is the inverse', () {
    final world = withTrigger(Trigger.onMove);
    run(world, moving: false);
    expect(world.abilities.first.waiting, isTrue);
    run(world, moving: true);
    expect(world.abilities.first.waiting, isFalse);
  });

  test('While Wounded is blocked at full health', () {
    final world = withTrigger(Trigger.onLowHp);
    run(world, moving: false, hp: 1.0);
    expect(world.abilities.first.waiting, isTrue);
    run(world, moving: false, hp: 0.2);
    expect(world.abilities.first.waiting, isFalse);
  });

  test('event-driven triggers report waiting alongside a self-starter', () {
    final world = World(32);
    world.abilities.clear();
    world.addAbility(Genome(
      vector: Vector.bolt,
      payload: Payload.kinetic,
      trigger: Trigger.timer,
      riders: const {},
    ));
    world.addAbility(Genome(
      vector: Vector.burst,
      payload: Payload.frost,
      trigger: Trigger.onKill,
      riders: const {},
    ));
    // Unkillable, so no kill event can fire.
    for (var i = 0; i < 6; i++) {
      final e = world.enemyPool.obtain();
      if (e == null) break;
      e.spawn(enemyDefs['crawler']!, 40.0 + i * 4, 0, 0, 100000.0);
    }
    run(world, moving: false, frames: 120);
    expect(world.abilities.last.waiting, isTrue,
        reason: 'an on-kill ability with no kills is waiting, not ready');
    expect(world.abilities.first.waiting, isFalse);
  });
}
