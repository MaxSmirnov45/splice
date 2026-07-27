import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genes.dart';
import 'package:splice/src/genome/genome.dart';

/// A loadout made entirely of event-driven abilities cannot start itself: an
/// on-kill effect needs something else to produce the first kill. Without a
/// safety net the run is silently unplayable — nothing fires, ever.
double _damageOver(World world, double seconds) {
  var before = 0.0;
  for (var i = 0; i < 16; i++) {
    final e = world.enemyPool.obtain();
    if (e == null) break;
    final ang = i * 0.4;
    e.spawn(enemyDefs['crawler']!, 40 * _c(ang), 40 * _s(ang), 0, 3000.0);
    before += e.maxHp;
  }
  for (var i = 0; i < seconds * 60; i++) {
    world.pendingLevelUps = 0;
    world.gameOver = false;
    world.hp = world.maxHp;
    world.update(1 / 60);
  }
  var after = 0.0;
  for (final e in world.enemies) {
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

  test('a normal loadout keeps event triggers event-driven', () {
    // With a self-starting ability present, an on-kill effect must NOT fall
    // back to firing on a timer, or the trigger stops meaning anything.
    final world = World(12);
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
    final onKill = world.abilities.last;

    // Enemies too tough to die, so no kill event can ever be raised.
    for (var i = 0; i < 8; i++) {
      final e = world.enemyPool.obtain();
      if (e == null) break;
      e.spawn(enemyDefs['crawler']!, 40.0 + i * 3, 0, 0, 100000.0);
    }
    for (var i = 0; i < 300; i++) {
      world.pendingLevelUps = 0;
      world.gameOver = false;
      world.hp = world.maxHp;
      world.update(1 / 60);
    }
    // Never fired, so its cooldown was never set.
    expect(onKill.cooldown, lessThanOrEqualTo(0),
        reason: 'on-kill fired without a kill; the fallback leaked into a '
            'normal loadout');
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
