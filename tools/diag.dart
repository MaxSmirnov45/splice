// Per-vector contribution diagnostic.
//
// Reports, for each vector used as a hybrid secondary, how much damage it adds
// over a bolt-only baseline and how many shots it keeps alive. Used to find
// secondaries that silently do nothing.
//
//   dart run tools/diag.dart

import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genes.dart';
import 'package:splice/src/genome/genome.dart';

class Sample {
  final double damage;
  final int peakShots;

  /// Enemies carrying the frost status. The secondary payload is frost and the
  /// primary is kinetic, so this is a direct read of whether the secondary is
  /// landing hits at all — independent of how much damage it does.
  final int slowed;

  const Sample(this.damage, this.peakShots, this.slowed);
}

Sample run(Genome g, {double seconds = 6.0}) {
  final world = World(99);
  world.abilities.clear();
  world.addAbility(g);

  var before = 0.0;
  for (var i = 0; i < 30; i++) {
    final e = world.enemyPool.obtain();
    if (e == null) break;
    final ang = i * 0.209;
    final dist = 26.0 + (i % 5) * 12.0;
    e.spawn(enemyDefs['crawler']!, world.px + dist * _cos(ang),
        world.py + dist * _sin(ang), 0, 4000.0);
    before += e.maxHp;
  }

  var peak = 0;
  for (var i = 0; i < (seconds * 60).round(); i++) {
    world.pendingLevelUps = 0;
    world.gameOver = false;
    world.hp = world.maxHp;
    world.inputX = (i ~/ 30) % 2 == 0 ? 1.0 : 0.0;
    world.update(1 / 60);
    final live = world.shotPool.liveCount;
    if (live > peak) peak = live;
  }

  var remaining = 0.0;
  var slowed = 0;
  for (final e in world.enemies) {
    if (!e.alive) continue;
    remaining += e.hp;
    if (e.slowTime > 0) slowed++;
  }
  return Sample(before - remaining, peak, slowed);
}

double _cos(double a) => _series(a + 1.5707963267948966);
double _sin(double a) => _series(a);
double _series(double a) {
  var x = a % 6.283185307179586;
  var term = x, sum = x;
  for (var n = 1; n < 9; n++) {
    term *= -x * x / ((2 * n) * (2 * n + 1));
    sum += term;
  }
  return sum;
}

void main() {
  final baseline = run(Genome(
    vector: Vector.bolt,
    payload: Payload.kinetic,
    trigger: Trigger.timer,
    riders: const {},
    generation: 1,
  ));
  // ignore: avoid_print
  print('baseline bolt              dmg=${baseline.damage.toStringAsFixed(1).padLeft(8)}  '
      'peakShots=${baseline.peakShots}  slowed=${baseline.slowed}');

  for (final v in Vector.values) {
    if (v == Vector.bolt) continue;
    final s = run(Genome(
      vector: Vector.bolt,
      subVector: v,
      payload: Payload.kinetic,
      subPayload: Payload.frost,
      trigger: Trigger.timer,
      riders: const {},
      generation: 1,
    ));
    final delta = s.damage - baseline.damage;
    final flag = delta <= baseline.damage * 0.02 ? '  <-- contributes nothing' : '';
    // ignore: avoid_print
    print('bolt + ${v.name.padRight(8)}          dmg=${s.damage.toStringAsFixed(1).padLeft(8)}  '
        'peakShots=${s.peakShots}  delta=${delta.toStringAsFixed(1).padLeft(7)}$flag');
  }
}
