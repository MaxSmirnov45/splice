import 'dart:math' as math;

/// Deterministic xorshift32.
///
/// The whole game is seedable: same seed, same run. That makes balance bugs
/// reproducible and lets a genome hash drive its own visual variation without
/// storing anything.
class Rng {
  int _s;

  Rng(int seed) : _s = (seed == 0 ? 0x9E3779B9 : seed) & 0xFFFFFFFF;

  /// Seeds from a string, stable across processes (unlike Object.hashCode).
  factory Rng.fromString(String s) {
    var h = 0x811C9DC5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return Rng(h);
  }

  int get seed => _s;

  int nextInt() {
    var x = _s;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _s = x & 0xFFFFFFFF;
    return _s;
  }

  /// Uniform in [0, 1).
  double next() => nextInt() / 4294967296.0;

  double range(double a, double b) => a + (b - a) * next();

  int rangeInt(int minInclusive, int maxExclusive) {
    if (maxExclusive <= minInclusive) return minInclusive;
    return minInclusive + nextInt() % (maxExclusive - minInclusive);
  }

  bool chance(double p) => next() < p;

  T pick<T>(List<T> items) => items[nextInt() % items.length];

  /// Uniform direction as a unit vector, returned via [out] to avoid garbage
  /// in the hot spawn path.
  void unitVector(List<double> out) {
    final a = next() * math.pi * 2;
    out[0] = math.cos(a);
    out[1] = math.sin(a);
  }

  /// Fisher-Yates, in place.
  void shuffle<T>(List<T> items) {
    for (var i = items.length - 1; i > 0; i--) {
      final j = nextInt() % (i + 1);
      final t = items[i];
      items[i] = items[j];
      items[j] = t;
    }
  }

  /// Picks an index from unnormalised weights.
  int weighted(List<double> weights) {
    var total = 0.0;
    for (final w in weights) {
      total += w;
    }
    if (total <= 0) return 0;
    var r = next() * total;
    for (var i = 0; i < weights.length; i++) {
      r -= weights[i];
      if (r <= 0) return i;
    }
    return weights.length - 1;
  }
}
