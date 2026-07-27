import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';

/// Ranged enemies are only fair if the telegraph is honest: the player must be
/// warned, the warning must point where the shot actually goes, and stepping
/// off that line must work.
Enemy place(World world, String archetype, double x, double y) {
  final e = world.enemyPool.obtain()!;
  e.spawn(enemyDefs[archetype]!, x, y, 0, 1.0);
  return e;
}

/// Runs the sim with no abilities, so nothing kills the shooter mid-test.
World bare() {
  final world = World(11);
  world.abilities.clear();
  return world;
}

void step(World world, double seconds) {
  for (var i = 0; i < (seconds * 60).round(); i++) {
    world.update(1 / 60);
  }
}

/// Advances until the shooter starts its wind-up.
///
/// Volleys are deliberately staggered on spawn so a wave that arrives together
/// does not fire in unison, so a test cannot assume it charges immediately.
void chargeUp(World world, Enemy e) {
  for (var i = 0; i < 60 * 8 && !e.charging; i++) {
    world.update(1 / 60);
  }
}

void main() {
  test('a shooter winds up before anything leaves the muzzle', () {
    final world = bare();
    final e = place(world, 'spitter', 150, 0);
    final w = e.def.ranged!;

    chargeUp(world, e);
    expect(e.charging, isTrue, reason: 'must telegraph once in range');
    expect(world.threatPool.liveCount, 0,
        reason: 'nothing may be fired during the wind-up');

    step(world, w.windup + 0.05);
    expect(world.threatPool.liveCount, greaterThan(0));
  });

  test('the volley goes exactly where the telegraph pointed', () {
    final world = bare();
    final e = place(world, 'spitter', 0, -150);
    chargeUp(world, e);
    expect(e.charging, isTrue);
    final aimX = e.aimX, aimY = e.aimY;

    // Teleporting the player mid-wind-up must not bend the shot: the line the
    // player saw is the line the shot takes.
    world.px = 400;
    world.py = 400;
    step(world, e.def.ranged!.windup + 0.05);

    final t = world.threats.firstWhere((t) => t.alive);
    final len = math.sqrt(t.vx * t.vx + t.vy * t.vy);
    expect(t.vx / len, closeTo(aimX, 0.02));
    expect(t.vy / len, closeTo(aimY, 0.02));
  });

  test('a fan is centred on the telegraphed direction', () {
    final world = bare();
    final e = place(world, 'lancer', 200, 0);
    final w = e.def.ranged!;
    chargeUp(world, e);
    step(world, w.windup + 0.05);

    final live = world.threats.where((t) => t.alive).toList();
    expect(live.length, w.shots);
    var sumX = 0.0, sumY = 0.0;
    for (final t in live) {
      final len = math.sqrt(t.vx * t.vx + t.vy * t.vy);
      sumX += t.vx / len;
      sumY += t.vy / len;
    }
    final mean = math.atan2(sumY / live.length, sumX / live.length);
    expect(mean, closeTo(math.atan2(e.aimY, e.aimX), 0.02));
  });

  test('a shot that reaches the player damages them', () {
    final world = bare();
    place(world, 'spitter', 120, 0);
    final before = world.hp;
    step(world, 6.0);
    expect(world.hp, lessThan(before));
  });

  test('stunning a shooter cancels its volley rather than banking it', () {
    final world = bare();
    final e = place(world, 'spitter', 150, 0);
    chargeUp(world, e);
    expect(e.charging, isTrue);

    e.stunTime = 0.5;
    step(world, e.def.ranged!.windup + 0.05);
    expect(world.threatPool.liveCount, 0,
        reason: 'a stunned shooter must not fire through the stun');
  });

  test('a shooter holds its standoff distance instead of closing', () {
    final world = bare();
    final e = place(world, 'spitter', 60, 0);
    step(world, 3.0);
    final dist = math.sqrt(
        (e.x - world.px) * (e.x - world.px) + (e.y - world.py) * (e.y - world.py));
    expect(dist, greaterThan(100),
        reason: 'it must back off to its firing range, not join the scrum');
  });

  test('shots expire rather than travelling forever', () {
    final world = bare();
    place(world, 'spitter', 200, 0);
    world.px = 20000;
    world.py = 20000;
    step(world, 12.0);
    expect(world.threatPool.liveCount, 0);
  });

  test('enemy fire is slower than it looks, so it can be outrun', () {
    for (final key in ['spitter', 'lancer']) {
      final w = enemyDefs[key]!.ranged!;
      expect(w.shotSpeed, lessThan(220),
          reason: '$key fire must be dodgeable on foot');
      expect(w.windup, greaterThanOrEqualTo(0.6),
          reason: '$key must give the player time to react');
    }
  });
}
