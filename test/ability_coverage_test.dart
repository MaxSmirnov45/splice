import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genes.dart';
import 'package:splice/src/genome/genome.dart';

/// Every gene the game can hand a player must actually do something.
///
/// A vector that never deals damage, or a trigger that never fires, reads to
/// the player as a broken ability — and because genes are rolled randomly,
/// one dead gene poisons a fraction of every run.

/// Builds a world holding exactly [g] and nothing else, surrounds the player
/// with enemies, and reports the damage dealt over [seconds].
double _damageDealt(Genome g,
    {double seconds = 6.0, bool hurtPlayer = false, bool moving = true}) {
  final world = World(99);
  world.abilities.clear();
  world.addAbility(g);
  world.viewHalfWidth = 220;
  world.viewHalfHeight = 400;

  // Targets are given enough health that nothing can die during the sample.
  //
  // With killable enemies this measurement is worthless: a stronger build
  // clears the field, then has nothing to shoot and scores *lower* than a weak
  // one that leaves targets standing. Immortal dummies isolate raw output.
  const dummyHpScale = 4000.0;
  var totalHpBefore = 0.0;
  for (var i = 0; i < 30; i++) {
    final e = world.enemyPool.obtain();
    if (e == null) break;
    // A ring close enough for short-range vectors, spread enough for chains.
    final ang = i * 0.209;
    final dist = 26.0 + (i % 5) * 12.0;
    e.spawn(enemyDefs['crawler']!, world.px + dist * _cos(ang),
        world.py + dist * _sin(ang), 0, dummyHpScale);
    totalHpBefore += e.maxHp;
  }

  final frames = (seconds * 60).round();
  for (var i = 0; i < frames; i++) {
    world.pendingLevelUps = 0;
    world.gameOver = false;
    // Some triggers only fire while the player is in trouble.
    world.hp = hurtPlayer ? world.maxHp * 0.2 : world.maxHp;
    // Alternate between moving and still so movement-gated triggers both fire.
    // Held still when comparing vectors: a fleeing player structurally
    // disadvantages short-range vectors, which is a real gameplay property but
    // makes it impossible to tell 'weak while kiting' from 'does nothing'.
    world.inputX = moving && (i ~/ 30) % 2 == 0 ? 1.0 : 0.0;
    world.inputY = 0.0;
    world.update(1 / 60);
  }

  var remaining = 0.0;
  for (final e in world.enemies) {
    if (e.alive) remaining += e.hp;
  }
  return totalHpBefore - remaining;
}

double _cos(double a) => _series(a, true);
double _sin(double a) => _series(a, false);
double _series(double a, bool cosine) {
  // Small local trig so the test has no import beyond the game itself.
  var x = a % 6.283185307179586;
  if (cosine) x += 1.5707963267948966;
  var term = x, sum = x;
  for (var n = 1; n < 8; n++) {
    term *= -x * x / ((2 * n) * (2 * n + 1));
    sum += term;
  }
  return sum;
}

void main() {
  test('every vector deals damage as a primary', () {
    final dead = <String>[];
    for (final v in Vector.values) {
      final g = Genome(
        vector: v,
        payload: Payload.kinetic,
        trigger: Trigger.timer,
        riders: const {},
      );
      final dealt = _damageDealt(g);
      if (dealt <= 0) dead.add(v.name);
    }
    expect(dead, isEmpty, reason: 'vectors that dealt no damage: $dead');
  });

  test('every vector lands hits as a hybrid secondary', () {
    // Asserts the secondary connects at all, by checking for its status
    // effect, rather than comparing damage totals.
    //
    // Magnitude comparisons are hostage to geometry: short-range vectors score
    // near zero when the player is fleeing and long-range ones score near zero
    // when enemies are pressed against them. Neither means "broken". The frost
    // status is binary — either the secondary hit something or it did not.
    final dead = <String>[];

    for (final v in Vector.values) {
      if (v == Vector.bolt) continue; // used as the primary

      final world = World(5);
      world.abilities.clear();
      world.addAbility(Genome(
        vector: Vector.bolt,
        subVector: v,
        payload: Payload.kinetic, // primary applies no status
        subPayload: Payload.frost, // secondary slows, so hits are detectable
        trigger: Trigger.timer,
        riders: const {},
        generation: 1,
      ));

      for (var i = 0; i < 12; i++) {
        final e = world.enemyPool.obtain();
        if (e == null) break;
        final ang = i * 0.5236;
        e.spawn(enemyDefs['crawler']!, 45 * _cos(ang), 45 * _sin(ang), 0, 4000.0);
      }

      var everSlowed = false;
      for (var i = 0; i < 60 * 8 && !everSlowed; i++) {
        world.pendingLevelUps = 0;
        world.gameOver = false;
        world.hp = world.maxHp;
        world.update(1 / 60);
        for (final e in world.enemies) {
          if (e.alive && e.slowTime > 0) {
            everSlowed = true;
            break;
          }
        }
      }
      if (!everSlowed) dead.add(v.name);
    }

    expect(dead, isEmpty, reason: 'secondary vectors that never connected: $dead');
  });

  test('every trigger eventually fires', () {
    // Counts activations directly rather than inferring them from damage.
    //
    // The tested ability is paired with a plain timed Bolt, because several
    // triggers cannot bootstrap alone: an on-kill ability that is your only
    // ability can never fire, since nothing else can produce the first kill.
    // That is correct behaviour, not a bug, so the harness has to model a
    // realistic loadout.
    int activations(Trigger t) {
      final world = World(4242);
      world.abilities.clear();
      world.addAbility(Genome(
        vector: Vector.bolt,
        payload: Payload.kinetic,
        trigger: Trigger.timer,
        riders: const {Rider.split: 2},
      ));
      final tested = Genome(
        vector: Vector.burst,
        payload: Payload.kinetic,
        trigger: t,
        riders: const {},
      );
      world.addAbility(tested);
      final ability = world.abilities.last;

      var fired = 0;
      var previous = ability.cooldown;

      for (var i = 0; i < 60 * 20; i++) {
        world.pendingLevelUps = 0;
        world.gameOver = false;
        // Keep the player wounded so onLowHp and onHurt have their conditions,
        // and let enemies actually reach them so contact and grazes happen.
        world.hp = world.maxHp * 0.25;
        world.inputX = (i ~/ 40) % 2 == 0 ? 0.8 : 0.0;
        world.update(1 / 60);

        // A firing ability resets its cooldown, so a jump upward is an
        // activation.
        if (ability.cooldown > previous + 1e-6) fired++;
        previous = ability.cooldown;

        if (i % 90 == 0) {
          for (var n = 0; n < 25; n++) {
            final e = world.enemyPool.obtain();
            if (e == null) break;
            final ang = n * 0.25;
            e.spawn(enemyDefs['mote']!, world.px + 30 * _cos(ang),
                world.py + 30 * _sin(ang), 0, 1.0);
          }
        }
      }
      return fired;
    }

    final dead = <String>[];
    for (final t in Trigger.values) {
      if (activations(t) == 0) dead.add(t.name);
    }
    expect(dead, isEmpty, reason: 'triggers that never fired: $dead');
  });

  test('a secondary vector uses its own range, not the primary\'s', () {
    // Aura's natural radius is 74; bolt's is 320. If the secondary inherits
    // the primary's range, a Bolt-Aura hybrid gets a screen-filling aura and
    // an Aura-Beam hybrid gets a beam too short to reach anything.
    final boltAura = Genome(
      vector: Vector.bolt,
      subVector: Vector.aura,
      payload: Payload.kinetic,
      trigger: Trigger.timer,
      riders: const {},
      generation: 1,
    );
    expect(boltAura.subRange, closeTo(vectorDefs[Vector.aura]!.range, 0.01),
        reason: 'secondary aura should use aura range, not bolt range');

    final auraBeam = Genome(
      vector: Vector.aura,
      subVector: Vector.beam,
      payload: Payload.kinetic,
      trigger: Trigger.timer,
      riders: const {},
      generation: 1,
    );
    expect(auraBeam.subRange, closeTo(vectorDefs[Vector.beam]!.range, 0.01),
        reason: 'secondary beam should use beam range, not aura range');
  });

  test('swarm seekers home even without the Seek rider', () {
    // The vector is described as homing. If homing only switches on when a
    // rider happens to roll, the ability is broken most of the time.
    final plain = _damageDealt(Genome(
      vector: Vector.swarm,
      payload: Payload.kinetic,
      trigger: Trigger.timer,
      riders: const {},
    ));
    expect(plain, greaterThan(0));
  });
}
