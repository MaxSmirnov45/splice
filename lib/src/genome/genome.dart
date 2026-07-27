import 'dart:math' as math;

import '../core/rng.dart';
import 'genes.dart';

/// A single ability, expressed as a genome and the stats derived from it.
///
/// A genome carries a *primary* vector and payload plus an optional
/// *secondary* pair inherited from the other parent. That secondary slot is
/// what makes a splice legible: the offspring of an Orbit and a Beam actually
/// orbits *and* fires a beam, rather than being one parent wearing the other's
/// colour. With only single slots, crossover can express one parent per gene
/// and the other's contribution is invisible.
///
/// When both parents share a gene there is nothing to hybridise, so the child
/// specialises instead: no secondary, but a concentration bonus. Hybrid vigour
/// buys coverage; pure lineage buys power.
class Genome {
  /// Damage a secondary vector deals, relative to the primary.
  static const double subVectorPower = 0.45;

  /// Damage bonus when both parents contributed the same vector.
  static const double pureVectorBonus = 0.25;

  /// Damage bonus when both parents contributed the same payload.
  static const double purePayloadBonus = 0.20;

  final Vector vector;

  /// Second delivery method, inherited from the other parent. Null when the
  /// lineage is pure.
  final Vector? subVector;

  final Payload payload;

  /// Second damage type, applied alongside the primary at reduced magnitude.
  final Payload? subPayload;

  final Trigger trigger;

  /// Rider -> stack count. Absent means zero. Counts are unbounded.
  final Map<Rider, int> riders;

  /// How many splices deep this genome is.
  final int generation;

  /// Stable per-genome value used for naming and sigil variation.
  final int seed;

  // --- derived stats, computed once at construction ---
  late final double damage;
  late final double cooldown;
  late final int count;
  late final int pierce;
  late final double range;
  late final double speed;
  late final double life;
  late final double seekStrength;
  late final double knockback;
  late final double statusDuration;
  late final double dotPerSecond;
  late final double bloomChance;
  late final double leechFraction;
  late final double echoChance;
  late final double greedBonus;

  /// Multiplier the Ferment rider applies to status durations.
  ///
  /// Exposed separately from [statusDuration] because a hybrid's secondary
  /// payload has its own base duration; scaling must be applied to whichever
  /// payload is actually landing, not to the primary's.
  late final double fermentScale;

  /// Damage, instance count and reach for the secondary vector, if present.
  late final double subDamage;
  late final int subCount;

  /// The secondary's own range.
  ///
  /// It must not inherit the primary's: bolt reaches 320 and aura only 74, so
  /// sharing one number gives a Bolt-Aura hybrid a screen-filling aura and an
  /// Aura-Beam hybrid a beam too short to touch anything.
  late final double subRange;

  Genome({
    required this.vector,
    required this.payload,
    required this.trigger,
    required Map<Rider, int> riders,
    this.subVector,
    this.subPayload,
    this.generation = 0,
    this.seed = 1,
  }) : riders = Map.unmodifiable(riders) {
    final v = vectorDefs[vector]!;
    final p = payloadDefs[payload]!;
    final t = triggerDefs[trigger]!;

    // A small flat multiplier per splice, so a deep lineage is worth something
    // even if its riders are unlucky. Kept low because riders now inherit from
    // both parents rather than just the stronger one, which already compounds.
    final genScale = 1.0 + 0.038 * generation;

    // Purity bonuses stand in for the secondary the child did not get.
    var concentration = 1.0;
    if (generation > 0 && subVector == null) concentration += pureVectorBonus;
    if (generation > 0 && subPayload == null) concentration += purePayloadBonus;

    damage = v.damage *
        p.damageMul *
        t.damageMul *
        (1 + _rider(Rider.amplify)) *
        genScale *
        concentration;
    cooldown = math.max(0.05, v.cooldown * t.cooldownMul / (1 + _rider(Rider.rapid)));
    count = v.count + (_rider(Rider.split) * v.splitAffinity).floor();
    pierce = v.pierce < 0 ? -1 : v.pierce + _rider(Rider.pierce).floor();
    range = v.range * (1 + _rider(Rider.reach));
    speed = v.speed;
    life = v.life;
    seekStrength = _rider(Rider.seek);
    knockback = _rider(Rider.weight);
    fermentScale = 1 + _rider(Rider.ferment);
    statusDuration = p.statusDuration * fermentScale;
    dotPerSecond = p.dotPerSecond;
    bloomChance = _asymptote(_rider(Rider.bloom), 0.85);
    echoChance = _asymptote(_rider(Rider.echo), 0.80);
    leechFraction = _asymptote(_rider(Rider.leech), 0.35);
    greedBonus = _rider(Rider.greed);

    if (subVector != null) {
      final sv = vectorDefs[subVector]!;
      subDamage = sv.damage * p.damageMul * t.damageMul *
          (1 + _rider(Rider.amplify)) * genScale * subVectorPower;
      // Halved instance count keeps a hybrid from doubling the entity budget.
      subCount = math.max(1, (sv.count + (_rider(Rider.split) * sv.splitAffinity).floor()) ~/ 2);
      subRange = sv.range * (1 + _rider(Rider.reach));
    } else {
      subDamage = 0;
      subCount = 0;
      subRange = 0;
    }
  }

  /// Effective magnitude of a rider: perStack * count^exponent.
  double _rider(Rider r) {
    final n = riders[r] ?? 0;
    if (n <= 0) return 0;
    final def = riderDefs[r]!;
    return def.perStack * math.pow(n, def.exponent).toDouble();
  }

  /// Maps [0, inf) onto [0, limit) so a chance can grow forever without
  /// becoming a guarantee.
  static double _asymptote(double raw, double limit) => limit * (1 - math.exp(-raw / limit));

  int stacksOf(Rider r) => riders[r] ?? 0;

  int get totalStacks => riders.values.fold(0, (a, b) => a + b);

  bool get isHybrid => subVector != null || subPayload != null;

  /// How elaborate this ability should look in the world, 0..5.
  ///
  /// Drives layered decoration on projectiles — orbiting motes, halos,
  /// counter-rotating rings, a hotter core. Without it a generation-8 ability
  /// renders identically to a generation-0 one and all that evolution is
  /// invisible outside the menu.
  ///
  /// Rider stacks count as well as generation, so a heavily modified wild
  /// spore also earns its look rather than needing a splice for it.
  int get visualTier {
    final t = generation + totalStacks ~/ 4;
    return t.clamp(0, 5);
  }

  /// Every vector this genome delivers through.
  List<Vector> get vectors => subVector == null ? [vector] : [vector, subVector!];

  /// Every payload this genome applies.
  List<Payload> get payloads => subPayload == null ? [payload] : [payload, subPayload!];

  /// Sustained damage per second, ignoring travel time and overkill. Used to
  /// rank abilities in the UI and to sanity-check balance in tests.
  double get dps {
    final primary = damage * count * (1 + echoChance);
    final secondary = subDamage * subCount * (1 + echoChance);
    final dot = dotPerSecond > 0 ? damage * dotPerSecond * statusDuration * count : 0.0;
    return (primary + secondary + dot) / cooldown;
  }

  String get displayName {
    final adj = payloadAdjective[payload]!;
    final noun = vectorDefs[vector]!.name;
    final base = subVector == null
        ? '$adj $noun'
        : '$adj $noun-${vectorDefs[subVector]!.name}';
    return generation > 0 ? '$base ${_numeral(generation)}' : base;
  }

  /// "Frost + Burn", or just "Frost" for a pure lineage.
  String get payloadLabel => subPayload == null
      ? payloadDefs[payload]!.name
      : '${payloadDefs[payload]!.name} + ${payloadDefs[subPayload]!.name}';

  String get triggerLabel => triggerDefs[trigger]!.name;

  static String _numeral(int n) {
    const numerals = [
      [1000, 'M'], [900, 'CM'], [500, 'D'], [400, 'CD'], [100, 'C'], [90, 'XC'],
      [50, 'L'], [40, 'XL'], [10, 'X'], [9, 'IX'], [5, 'V'], [4, 'IV'], [1, 'I'],
    ];
    var remaining = n;
    final out = StringBuffer();
    for (final entry in numerals) {
      final value = entry[0] as int;
      final symbol = entry[1] as String;
      while (remaining >= value) {
        out.write(symbol);
        remaining -= value;
      }
    }
    return out.toString();
  }

  // --- construction -------------------------------------------------------

  /// A wild spore: random genes, always pure. Hybrids are something the player
  /// makes, never something they find.
  factory Genome.wild(Rng rng, {int power = 0}) {
    final riders = <Rider, int>{};
    final pool = List<Rider>.from(Rider.values);
    rng.shuffle(pool);
    final riderCount = 1 + (power ~/ 3).clamp(0, 3);
    for (var i = 0; i < riderCount && i < pool.length; i++) {
      riders[pool[i]] = 1 + rng.rangeInt(0, 1 + power ~/ 4);
    }
    return Genome(
      vector: rng.pick(Vector.values),
      payload: rng.pick(Payload.values),
      // Weight the timer trigger heavily: event triggers are interesting but a
      // starting hand full of them feels unresponsive.
      trigger: rng.chance(0.55) ? Trigger.timer : rng.pick(Trigger.values),
      riders: riders,
      generation: 0,
      seed: rng.nextInt(),
    );
  }

  /// The ability every run begins with. Fixed, so openings are learnable.
  factory Genome.starter() => Genome(
        vector: Vector.bolt,
        payload: Payload.kinetic,
        trigger: Trigger.timer,
        riders: const {},
        generation: 0,
        seed: 0x5EED,
      );

  /// Breeds [a] and [b] into a single offspring.
  ///
  /// Both parents are always visible in the result. Differing vectors become
  /// primary and secondary; matching vectors concentrate into a damage bonus.
  /// Riders take the better parent's stacks plus half the weaker one's, so the
  /// lesser parent still leaves a mark.
  ///
  /// The cost is paid elsewhere: splicing consumes both parents, trading
  /// breadth for depth while the swarm adapts to whatever the player leans on.
  static Genome splice(Genome a, Genome b, Rng rng) {
    final riders = <Rider, int>{};
    for (final r in Rider.values) {
      final x = a.stacksOf(r), y = b.stacksOf(r);
      if (x == 0 && y == 0) continue;
      // Both parents contribute; the weaker at half weight.
      riders[r] = math.max(x, y) + (math.min(x, y) * 0.5).floor();
    }

    // Which parent's gene leads is random, but both are always represented.
    final aLeadsVector = rng.chance(0.5);
    final primaryVector = aLeadsVector ? a.vector : b.vector;
    final otherVector = aLeadsVector ? b.vector : a.vector;

    final aLeadsPayload = rng.chance(0.5);
    final primaryPayload = aLeadsPayload ? a.payload : b.payload;
    final otherPayload = aLeadsPayload ? b.payload : a.payload;

    final child = Genome(
      vector: primaryVector,
      // A matching pair has nothing to hybridise, so the lineage stays pure.
      subVector: otherVector == primaryVector ? null : otherVector,
      payload: primaryPayload,
      subPayload: otherPayload == primaryPayload ? null : otherPayload,
      trigger: rng.chance(0.5) ? a.trigger : b.trigger,
      riders: riders,
      generation: math.max(a.generation, b.generation) + 1,
      seed: rng.nextInt(),
    );
    return child.mutated(rng);
  }

  /// Applies exactly one mutation.
  ///
  /// Weighted heavily toward riders. Gene swaps target the *secondary* slot
  /// wherever possible: replacing a primary gene is what made offspring stop
  /// resembling their parents, so it is now the rarest outcome by far.
  Genome mutated(Rng rng) {
    final riders = Map<Rider, int>.from(this.riders);
    final roll = rng.next();

    if (roll < 0.50) {
      // Deepen a rider the genome already carries.
      if (riders.isEmpty) {
        riders[rng.pick(Rider.values)] = 1;
      } else {
        final key = rng.pick(riders.keys.toList());
        riders[key] = riders[key]! + 1;
      }
    } else if (roll < 0.82) {
      // Acquire a rider it does not have yet, widening its behaviour.
      final missing = Rider.values.where((r) => !riders.containsKey(r)).toList();
      if (missing.isEmpty) {
        final key = rng.pick(riders.keys.toList());
        riders[key] = riders[key]! + 1;
      } else {
        riders[rng.pick(missing)] = 1;
      }
    } else if (roll < 0.90) {
      return _copy(riders: riders, trigger: _pickOther(rng, Trigger.values, trigger));
    } else if (roll < 0.96) {
      // Drift the secondary payload; the primary identity is untouched.
      return _copy(
          riders: riders,
          subPayload: _pickExcluding(rng, Payload.values, [payload, subPayload]),
          setSubPayload: true);
    } else {
      // Rarest: the secondary delivery drifts. A pure lineage can sprout one
      // here, which is the only way an unspliced ability gains a second vector.
      return _copy(
          riders: riders,
          subVector: _pickExcluding(rng, Vector.values, [vector, subVector]),
          setSubVector: true);
    }
    return _copy(riders: riders);
  }

  /// Picks a value guaranteed not to be [current].
  static T _pickOther<T>(Rng rng, List<T> values, T current) {
    final options = values.where((v) => v != current).toList();
    return options.isEmpty ? current : rng.pick(options);
  }

  /// Picks a value that is none of [excluded].
  ///
  /// Excluding the *current* secondary as well as the primary matters: a
  /// mutation that re-picks the gene already in the slot is a mutation the
  /// player cannot see, which reads as the splice having silently failed.
  static T _pickExcluding<T>(Rng rng, List<T> values, List<T?> excluded) {
    final options = values.where((v) => !excluded.contains(v)).toList();
    return options.isEmpty ? values.first : rng.pick(options);
  }

  /// [setSubVector]/[setSubPayload] distinguish "leave unchanged" from
  /// "explicitly set", since null is a meaningful value for those fields.
  Genome _copy({
    Vector? vector,
    Payload? payload,
    Trigger? trigger,
    Map<Rider, int>? riders,
    int? generation,
    Vector? subVector,
    Payload? subPayload,
    bool setSubVector = false,
    bool setSubPayload = false,
  }) =>
      Genome(
        vector: vector ?? this.vector,
        payload: payload ?? this.payload,
        trigger: trigger ?? this.trigger,
        riders: riders ?? this.riders,
        subVector: setSubVector ? subVector : this.subVector,
        subPayload: setSubPayload ? subPayload : this.subPayload,
        generation: generation ?? this.generation,
        seed: seed,
      );

  // --- serialisation ------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'v': vector.index,
        'p': payload.index,
        't': trigger.index,
        'g': generation,
        's': seed,
        if (subVector != null) 'sv': subVector!.index,
        if (subPayload != null) 'sp': subPayload!.index,
        'r': riders.map((k, v) => MapEntry(k.index.toString(), v)),
      };

  factory Genome.fromJson(Map<String, dynamic> j) => Genome(
        vector: Vector.values[j['v'] as int],
        payload: Payload.values[j['p'] as int],
        trigger: Trigger.values[j['t'] as int],
        subVector: j['sv'] == null ? null : Vector.values[j['sv'] as int],
        subPayload: j['sp'] == null ? null : Payload.values[j['sp'] as int],
        generation: j['g'] as int,
        seed: j['s'] as int,
        riders: (j['r'] as Map<String, dynamic>)
            .map((k, v) => MapEntry(Rider.values[int.parse(k)], v as int)),
      );

  @override
  String toString() => '$displayName [$triggerLabel] $payloadLabel '
      'dmg=${damage.toStringAsFixed(1)} cd=${cooldown.toStringAsFixed(2)} '
      'n=$count dps=${dps.toStringAsFixed(1)}';
}
