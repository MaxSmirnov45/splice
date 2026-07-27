// Prints the power curve produced by repeated splicing, so balance decisions
// are made against real numbers rather than intuition.
//
//   dart run tools/curve.dart

import 'dart:math' as math;

import 'package:splice/src/core/rng.dart';
import 'package:splice/src/genome/genome.dart';

void main() {
  const trials = 200;
  const generations = 40;

  // Median across many seeds: a single lineage is far too noisy to tune against.
  final perGen = List.generate(generations, (_) => <double>[]);

  for (var t = 0; t < trials; t++) {
    final rng = Rng(1000 + t);
    var g = Genome.starter();
    for (var i = 0; i < generations; i++) {
      g = Genome.splice(g, Genome.wild(rng, power: i), rng);
      perGen[i].add(g.dps);
    }
  }

  double median(List<double> xs) {
    final s = List<double>.from(xs)..sort();
    return s[s.length ~/ 2];
  }

  final start = Genome.starter().dps;
  print('gen  medianDPS   xStart   xPrev');
  print('  0  ${start.toStringAsFixed(1).padLeft(9)}     1.00x       -');

  var prev = start;
  for (var i = 0; i < generations; i++) {
    final m = median(perGen[i]);
    print('${(i + 1).toString().padLeft(3)}  '
        '${m.toStringAsFixed(1).padLeft(9)}  '
        '${(m / start).toStringAsFixed(2).padLeft(6)}x  '
        '${(m / prev).toStringAsFixed(3).padLeft(6)}x');
    prev = m;
  }

  final overall = math.pow(median(perGen.last) / start, 1 / generations);
  print('\ngeometric mean growth per generation: '
      '${overall.toStringAsFixed(3)}x');
  print('total over $generations generations: '
      '${(median(perGen.last) / start).toStringAsFixed(0)}x');
}
