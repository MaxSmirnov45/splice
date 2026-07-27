import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/rng.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genome.dart';

/// Two abilities must never share a slot.
///
/// Slots index the per-enemy hit-cooldown array, so a collision makes the two
/// abilities block each other's hits permanently — the symptom being an
/// ability that silently stops working the moment you learn another one.
void expectUniqueSlots(World world, String context) {
  final slots = world.abilities.map((a) => a.slot).toList();
  expect(slots.toSet().length, slots.length,
      reason: 'duplicate slot after $context: $slots');
  for (final s in slots) {
    expect(s, inInclusiveRange(0, maxAbilitySlots - 1),
        reason: 'slot out of range after $context');
  }
}

void main() {
  test('slots stay unique across a long sequence of adds and splices', () {
    final world = World(7);
    final rng = Rng(99);

    // Mirrors a real run: fill up, splice pairs, absorb more, repeat. This is
    // exactly the pattern that made the old incrementing counter wrap onto a
    // slot already in use.
    for (var round = 0; round < 60; round++) {
      while (world.abilities.length < maxAbilitySlots) {
        world.addAbility(Genome.wild(rng, power: round));
        expectUniqueSlots(world, 'add in round $round');
      }
      final a = world.abilities[rng.rangeInt(0, world.abilities.length)];
      var b = world.abilities[rng.rangeInt(0, world.abilities.length)];
      if (identical(a, b)) {
        b = world.abilities.firstWhere((x) => !identical(x, a));
      }
      world.spliceAbilities(a, b, Genome.splice(a.genome, b.genome, rng));
      expectUniqueSlots(world, 'splice in round $round');
    }
  });

  test('slots stay unique when abilities are replaced', () {
    final world = World(8);
    final rng = Rng(3);
    while (world.abilities.length < maxAbilitySlots) {
      world.addAbility(Genome.wild(rng, power: 2));
    }
    for (var i = 0; i < 40; i++) {
      final victim = world.abilities[rng.rangeInt(0, world.abilities.length)];
      world.replaceAbility(victim, Genome.wild(rng, power: 3));
      expectUniqueSlots(world, 'replace $i');
    }
  });

  test('a freed slot is reused rather than skipped', () {
    final world = World(9);
    final rng = Rng(5);
    while (world.abilities.length < maxAbilitySlots) {
      world.addAbility(Genome.wild(rng, power: 1));
    }
    // Consume two, freeing one slot.
    final a = world.abilities[1];
    final b = world.abilities[2];
    world.spliceAbilities(a, b, Genome.splice(a.genome, b.genome, rng));
    expect(world.abilities.length, maxAbilitySlots - 1);

    world.addAbility(Genome.wild(rng, power: 1));
    expect(world.abilities.length, maxAbilitySlots);
    expectUniqueSlots(world, 'refill after splice');
  });
}
