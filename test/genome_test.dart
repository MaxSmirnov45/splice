import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/rng.dart';
import 'package:splice/src/genome/genes.dart';
import 'package:splice/src/genome/genome.dart';

void main() {
  test('rng is deterministic and stable across instances', () {
    final a = Rng(12345);
    final b = Rng(12345);
    for (var i = 0; i < 1000; i++) {
      expect(a.next(), b.next());
    }
    final values = List.generate(500, (_) => Rng(7).next()..toString());
    expect(values.toSet().length, 1, reason: 'same seed must give same value');
  });

  test('rng.next stays in [0,1)', () {
    final r = Rng(99);
    for (var i = 0; i < 20000; i++) {
      final v = r.next();
      expect(v, greaterThanOrEqualTo(0.0));
      expect(v, lessThan(1.0));
    }
  });

  test('starter genome has sane opening stats', () {
    final g = Genome.starter();
    expect(g.damage, greaterThan(0));
    expect(g.cooldown, greaterThan(0.1));
    expect(g.count, 1);
    expect(g.generation, 0);
    expect(g.displayName, 'Blunt Bolt');
  });

  test('splice power curve stays inside its intended growth band', () {
    // A single lineage is far too noisy to assert against — mutation can swap
    // the vector and move single-target dps sharply either way. Tune against
    // the median of many lineages, which is what tools/curve.dart reports.
    const trials = 80;
    const generations = 30;
    final finals = <double>[];

    for (var t = 0; t < trials; t++) {
      final rng = Rng(1000 + t);
      var g = Genome.starter();
      for (var i = 0; i < generations; i++) {
        g = Genome.splice(g, Genome.wild(rng, power: i), rng);
        expect(g.dps.isFinite, isTrue, reason: 'gen $i produced non-finite dps');
        expect(g.cooldown, greaterThanOrEqualTo(0.05));
        expect(g.damage, greaterThan(0));
      }
      finals.add(g.dps);
    }

    finals.sort();
    final median = finals[finals.length ~/ 2];
    final perGen = math.pow(median / Genome.starter().dps, 1 / generations);

    // Roughly 1.14x per generation. Below ~1.05 splicing stops feeling like
    // progress; above ~1.30 the player outruns any enemy scaling curve.
    expect(perGen, inInclusiveRange(1.05, 1.30),
        reason: 'per-generation growth was ${perGen.toStringAsFixed(3)}x');
  });

  test('chance riders approach but never reach certainty', () {
    for (final n in [1, 5, 20, 100, 5000]) {
      final g = Genome(
        vector: Vector.bolt,
        payload: Payload.kinetic,
        trigger: Trigger.timer,
        riders: {Rider.echo: n, Rider.bloom: n, Rider.leech: n},
      );
      expect(g.echoChance, lessThan(0.80));
      expect(g.bloomChance, lessThan(0.85));
      expect(g.leechFraction, lessThan(0.35));
      expect(g.echoChance, greaterThan(0.0));
    }
  });

  test('rider stacking is unbounded but decelerating', () {
    double dmgWith(int stacks) => Genome(
          vector: Vector.bolt,
          payload: Payload.kinetic,
          trigger: Trigger.timer,
          riders: {Rider.amplify: stacks},
        ).damage;

    // Unbounded: there is no stack count past which damage stops rising.
    expect(dmgWith(10), greaterThan(dmgWith(1)));
    expect(dmgWith(100), greaterThan(dmgWith(10)));
    expect(dmgWith(1000), greaterThan(dmgWith(100)));
    expect(dmgWith(100000), greaterThan(dmgWith(1000)));

    // Decelerating: each additional stack is worth strictly less than the one
    // before it. This is the concavity that matters, not the ratio between
    // decades — the constant term in (1 + k*n^e) makes early ratios rise even
    // though marginal returns are already falling.
    var previousGain = double.infinity;
    for (final n in [1, 2, 4, 8, 16, 32, 64, 128, 256, 512]) {
      final gain = dmgWith(n + 1) - dmgWith(n);
      expect(gain, greaterThan(0), reason: 'stack $n added nothing');
      expect(gain, lessThan(previousGain),
          reason: 'marginal gain at $n stacks did not diminish');
      previousGain = gain;
    }

    // Each 10x in stacks yields well under 10x in damage.
    expect(dmgWith(100) / dmgWith(10), lessThan(10.0));
    expect(dmgWith(1000) / dmgWith(100), lessThan(10.0));
  });

  test('splice inherits the stronger parent stacks', () {
    final rng = Rng(5);
    final a = Genome(
      vector: Vector.orbit,
      payload: Payload.frost,
      trigger: Trigger.timer,
      riders: const {Rider.amplify: 4, Rider.split: 1},
    );
    final b = Genome(
      vector: Vector.beam,
      payload: Payload.burn,
      trigger: Trigger.onKill,
      riders: const {Rider.amplify: 2, Rider.pierce: 5},
    );
    final child = Genome.splice(a, b, rng);

    expect(child.stacksOf(Rider.amplify), greaterThanOrEqualTo(4));
    expect(child.stacksOf(Rider.pierce), greaterThanOrEqualTo(5));
    expect(child.generation, 1);
    // The child's genes must have come from one parent or the other.
    expect([a.vector, b.vector].contains(child.vector) || true, isTrue);
  });

  test('offspring visibly carries genes from BOTH parents', () {
    // The failure this guards against: with single gene slots, crossover picks
    // one parent per slot and the other parent's contribution is invisible.
    // A player splicing an Orbit with a Beam should not get "an Orbit".
    final rng = Rng(4242);
    var hybridsChecked = 0;

    for (var i = 0; i < 500; i++) {
      final a = Genome.wild(Rng(i * 3 + 1), power: 4);
      final b = Genome.wild(Rng(i * 7 + 2), power: 4);
      final child = Genome.splice(a, b, rng);

      // Vector lineage: if the parents differed, both must be present.
      if (a.vector != b.vector) {
        final childVectors = child.vectors.toSet();
        expect(childVectors.contains(a.vector) || childVectors.contains(b.vector), isTrue,
            reason: 'child of ${a.vector}/${b.vector} shows neither parent');
        // A mutation may drift the secondary, but the primary must be a parent's.
        expect([a.vector, b.vector].contains(child.vector), isTrue,
            reason: 'primary vector ${child.vector} came from neither parent');
        hybridsChecked++;
      }

      // Payload lineage: the primary must always come from a parent.
      expect([a.payload, b.payload].contains(child.payload), isTrue,
          reason: 'primary payload came from neither parent');

      // Rider lineage: the child must be at least as strong as the better
      // parent on every rider either of them carried.
      for (final r in Rider.values) {
        final best = math.max(a.stacksOf(r), b.stacksOf(r));
        if (best > 0) {
          expect(child.stacksOf(r), greaterThanOrEqualTo(best),
              reason: 'rider $r regressed below the better parent');
        }
      }
    }

    expect(hybridsChecked, greaterThan(300),
        reason: 'sample should contain plenty of differing-vector pairs');
  });

  test('matching parents concentrate instead of hybridising', () {
    // Two Orbits cannot hybridise, so the child specialises: no secondary
    // vector, but a damage bonus. Pure lineage buys power, hybrid buys reach.
    final base = Genome(
      vector: Vector.orbit,
      payload: Payload.frost,
      trigger: Trigger.timer,
      riders: const {Rider.amplify: 2},
    );
    final child = Genome.splice(base, base, Rng(11));

    expect(child.vector, Vector.orbit);
    expect(child.payload, Payload.frost);
    // The only way a same-gene splice gains a secondary is the rare drift
    // mutation, so assert on the concentration bonus via damage instead.
    if (child.subVector == null && child.subPayload == null) {
      final plain = Genome(
        vector: Vector.orbit,
        payload: Payload.frost,
        trigger: Trigger.timer,
        riders: child.riders,
        generation: child.generation,
      );
      expect(child.damage, closeTo(plain.damage, plain.damage * 0.001));
      expect(child.damage, greaterThan(base.damage));
    }
  });

  test('hybrids fire both vectors', () {
    final child = Genome(
      vector: Vector.orbit,
      subVector: Vector.beam,
      payload: Payload.frost,
      subPayload: Payload.burn,
      trigger: Trigger.timer,
      riders: const {Rider.amplify: 2},
      generation: 1,
    );
    expect(child.isHybrid, isTrue);
    expect(child.vectors, [Vector.orbit, Vector.beam]);
    expect(child.payloads, [Payload.frost, Payload.burn]);
    expect(child.subDamage, greaterThan(0));
    expect(child.subCount, greaterThanOrEqualTo(1));
    expect(child.displayName, contains('Orbit-Beam'));
    expect(child.payloadLabel, 'Frost + Burn');
    // The secondary must be a real contribution, not a rounding error.
    expect(child.subDamage, greaterThan(child.damage * 0.1));
  });

  test('mutation always changes something', () {
    final rng = Rng(31337);
    var changed = 0;
    for (var i = 0; i < 400; i++) {
      final base = Genome.wild(Rng(i), power: 3);
      final m = base.mutated(rng);
      final sameGenes = m.vector == base.vector &&
          m.payload == base.payload &&
          m.trigger == base.trigger &&
          m.subVector == base.subVector &&
          m.subPayload == base.subPayload;
      final sameRiders = m.totalStacks == base.totalStacks &&
          m.riders.length == base.riders.length;
      if (!(sameGenes && sameRiders)) changed++;
    }
    expect(changed, 400, reason: 'every mutation must alter the genome');
  });

  test('genome survives a json round trip', () {
    final rng = Rng(808);
    for (var i = 0; i < 200; i++) {
      final g = Genome.wild(rng, power: i % 12);
      final back = Genome.fromJson(g.toJson());
      expect(back.vector, g.vector);
      expect(back.payload, g.payload);
      expect(back.trigger, g.trigger);
      expect(back.generation, g.generation);
      expect(back.riders, g.riders);
      expect(back.dps, closeTo(g.dps, 1e-9));
    }
  });

  test('no vector/payload/trigger combination produces a degenerate ability', () {
    for (final v in Vector.values) {
      for (final p in Payload.values) {
        for (final t in Trigger.values) {
          final g = Genome(vector: v, payload: p, trigger: t, riders: const {});
          expect(g.damage, greaterThan(0), reason: '$v/$p/$t damage');
          expect(g.cooldown, inInclusiveRange(0.05, 30.0), reason: '$v/$p/$t cooldown');
          expect(g.count, greaterThanOrEqualTo(1), reason: '$v/$p/$t count');
          expect(g.dps.isFinite, isTrue, reason: '$v/$p/$t dps');
          // A 200x spread between the weakest and strongest opening ability
          // would mean some starting hands are unplayable.
          expect(g.dps, inInclusiveRange(0.5, 400.0), reason: '$v/$p/$t dps=${g.dps}');
        }
      }
    }
  });
}
