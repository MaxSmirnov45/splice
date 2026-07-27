import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/genome/genes.dart';
import 'package:splice/src/genome/genome.dart';

/// Every gene must carry player-facing text. A missing blurb produces a
/// description with a hole in it, which is worse than no description at all.
void main() {
  test('every vector explains how it delivers damage', () {
    for (final e in vectorDefs.entries) {
      expect(e.value.blurb, isNotEmpty, reason: '${e.key} has no blurb');
      expect(e.value.blurb[0], equals(e.value.blurb[0].toLowerCase()),
          reason: '${e.key} blurb must be a lower-case verb phrase');
    }
  });

  test('every payload with a side effect explains it', () {
    for (final e in payloadDefs.entries) {
      expect(e.value.blurb, isNotEmpty, reason: '${e.key} has no blurb');
      expect(e.value.blurb.endsWith('.'), isTrue,
          reason: '${e.key} blurb must be a sentence');
    }
  });

  test('every trigger names its condition, and gated ones carry a badge', () {
    for (final e in triggerDefs.entries) {
      expect(e.value.condition, isNotEmpty, reason: '${e.key} has no condition');
      final gated = e.value.eventDriven ||
          e.key == Trigger.onMove ||
          e.key == Trigger.onStill ||
          e.key == Trigger.onLowHp;
      if (gated) {
        expect(e.value.badge, isNotEmpty,
            reason: '${e.key} can block, so the bar must be able to say why');
        expect(e.value.badge.length, lessThanOrEqualTo(14),
            reason: '${e.key} badge must fit a 34px tile');
      } else {
        expect(e.value.badge, isEmpty,
            reason: '${e.key} never blocks, so it must not claim to');
      }
    }
  });

  test('every rider says what a stack does', () {
    for (final e in riderDefs.entries) {
      expect(e.value.blurb, isNotEmpty, reason: '${e.key} has no blurb');
    }
  });

  test('descriptions are whole sentences for every gene combination', () {
    for (final v in Vector.values) {
      for (final p in Payload.values) {
        for (final t in Trigger.values) {
          final d = Genome(vector: v, payload: p, trigger: t, riders: const {})
              .description;
          expect(d[0], equals(d[0].toUpperCase()));
          expect(d, contains('Fires '));
          expect(d, isNot(contains('..')));
          expect(d, isNot(contains('  ')));
        }
      }
    }
  });

  test('a hybrid describes both of its vectors', () {
    final child = Genome(
      vector: Vector.bolt,
      subVector: Vector.aura,
      payload: Payload.burn,
      trigger: Trigger.timer,
      riders: const {},
    );
    expect(child.description, contains('projectile'));
    expect(child.description, contains('field around you'));
    expect(child.description, contains('alight'));
  });
}
