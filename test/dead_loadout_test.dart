import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genes.dart';
import 'package:splice/src/genome/genome.dart';

/// A loadout made entirely of event-driven abilities cannot start itself: an
/// on-kill effect needs something else to produce the first kill. Without a
/// safety net the run is silently unplayable — nothing fires, ever.
double _damageOver(World world, double seconds) {
  // Tracked individually rather than by summing the whole pool: the spawner
  // keeps adding enemies during the run, and their health would otherwise be
  // counted as damage undone.
  final marked = <Enemy>[];
  var before = 0.0;
  for (var i = 0; i < 16; i++) {
    final e = world.enemyPool.obtain();
    if (e == null) break;
    final ang = i * 0.4;
    e.spawn(enemyDefs['crawler']!, 40 * _c(ang), 40 * _s(ang), 0, 3000.0);
    marked.add(e);
    before += e.maxHp;
  }
  for (var i = 0; i < seconds * 60; i++) {
    world.pendingLevelUps = 0;
    world.gameOver = false;
    world.hp = world.maxHp;
    world.update(1 / 60);
  }
  var after = 0.0;
  for (final e in marked) {
    if (e.alive) after += e.hp;
  }
  return before - after;
}

double _c(double a) => _ser(a + 1.5707963267948966);
double _s(double a) => _ser(a);
double _ser(double a) {
  var x = a % 6.283185307179586;
  var t = x, s = x;
  for (var n = 1; n < 9; n++) {
    t *= -x * x / ((2 * n) * (2 * n + 1));
    s += t;
  }
  return s;
}

void main() {
  test('an all-event-driven loadout still fires', () {
    for (final trigger in [Trigger.onKill, Trigger.onCrit, Trigger.onDodge, Trigger.onHurt]) {
      final world = World(11);
      world.abilities.clear();
      world.addAbility(Genome(
        vector: Vector.chain,
        payload: Payload.kinetic,
        trigger: trigger,
        riders: const {},
      ));
      expect(_damageOver(world, 5), greaterThan(0),
          reason: '$trigger alone produced no damage — the run would be dead');
    }
  });

  // The regression this file exists for. The fallback used to be a property of
  // the whole loadout: event-driven abilities ran freely on their cooldowns
  // only while nothing else could start itself. Picking up one timed ability
  // therefore throttled every event-driven ability the player already had —
  // which is indistinguishable, in play, from the new ability breaking the old
  // ones.
  test('learning a timed ability does not throttle the event-driven ones', () {
    int firingsOfStarvedEventAbility({required bool withTimedAbility}) {
      final world = World(12);
      world.abilities.clear();
      // Held still, or newly spawned enemies reach the player and raise the
      // very event this test is trying to starve.
      world.spawningEnabled = false;
      if (withTimedAbility) {
        world.addAbility(Genome(
          vector: Vector.bolt,
          payload: Payload.kinetic,
          trigger: Trigger.timer,
          riders: const {},
        ));
      }
      world.addAbility(Genome(
        vector: Vector.burst,
        payload: Payload.frost,
        trigger: Trigger.onHurt,
        riders: const {},
      ));
      final watched = world.abilities.last;

      // Unkillable and out of reach, so the ability is starved of its event
      // and only the idle fallback can fire it.
      for (var i = 0; i < 8; i++) {
        final e = world.enemyPool.obtain();
        if (e == null) break;
        e.spawn(enemyDefs['crawler']!, 900.0 + i * 3, 0, 0, 1000000.0);
      }

      var fired = 0;
      var lastCooldown = watched.cooldown;
      for (var i = 0; i < 60 * 20; i++) {
        world.pendingLevelUps = 0;
        world.gameOver = false;
        world.hp = world.maxHp;
        world.update(1 / 60);
        if (watched.cooldown > lastCooldown) fired++;
        lastCooldown = watched.cooldown;
      }
      return fired;
    }

    final alone = firingsOfStarvedEventAbility(withTimedAbility: false);
    final alongside = firingsOfStarvedEventAbility(withTimedAbility: true);
    expect(alone, greaterThan(0), reason: 'the fallback must fire it at all');
    expect(alongside, alone,
        reason: 'adding a timed ability changed how often the on-hurt ability '
            'fired — learning a skill must never weaken an equipped one');
  });

  test('an event still fires its ability immediately, not on the fallback',
      () {
    final world = World(14);
    world.abilities.clear();
    world.spawningEnabled = false;
    world.addAbility(Genome(
      vector: Vector.burst,
      payload: Payload.frost,
      trigger: Trigger.onHurt,
      riders: const {},
    ));
    final onHurt = world.abilities.single;

    // Pressed right up against the player, so hits land constantly.
    for (var i = 0; i < 8; i++) {
      final e = world.enemyPool.obtain();
      if (e == null) break;
      e.spawn(enemyDefs['crawler']!, 4.0 + i, 0, 0, 1000000.0);
    }

    var fired = 0;
    var lastCooldown = onHurt.cooldown;
    for (var i = 0; i < 60 * 10; i++) {
      world.pendingLevelUps = 0;
      world.gameOver = false;
      world.hp = world.maxHp;
      world.update(1 / 60);
      if (onHurt.cooldown > lastCooldown) fired++;
      lastCooldown = onHurt.cooldown;
    }
    // Ten seconds of constant hits must beat the ~3 activations the idle
    // fallback alone would have produced.
    expect(fired, greaterThan(5),
        reason: 'being hit constantly must fire an on-hurt ability far more '
            'often than the starvation fallback would');
  });

  test('chain and beam leave a visible arc', () {
    for (final v in [Vector.chain, Vector.beam]) {
      final world = World(13);
      world.abilities.clear();
      world.addAbility(Genome(
        vector: v,
        payload: Payload.shock,
        trigger: Trigger.timer,
        riders: const {},
      ));
      for (var i = 0; i < 6; i++) {
        final e = world.enemyPool.obtain();
        if (e == null) break;
        e.spawn(enemyDefs['crawler']!, 40.0 + i * 12, 0, 0, 3000.0);
      }
      var sawArc = false;
      for (var i = 0; i < 240 && !sawArc; i++) {
        world.pendingLevelUps = 0;
        world.gameOver = false;
        world.hp = world.maxHp;
        world.update(1 / 60);
        sawArc = world.arcs.any((a) => a.alive);
      }
      expect(sawArc, isTrue, reason: '$v produced no visible arc');
    }
  });
}
