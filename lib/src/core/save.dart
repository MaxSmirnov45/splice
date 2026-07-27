import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../genome/genes.dart';
import '../genome/genome.dart';

/// Persistent player record.
///
/// Deliberately limited to records and a codex of genes the player has seen.
/// Balance-affecting meta-progression is not here yet: tuning permanent power
/// gains without playtest data is the fastest way to wreck a difficulty curve,
/// and the run itself is already the progression.
class SaveData {
  static const _key = 'splice.save.v1';

  int runs;
  double bestTime;
  int bestLevel;
  int bestKills;
  int deepestGeneration;
  int totalKills;

  /// Audio levels, 0..1. Persisted so the player sets them once.
  double soundVolume;
  double musicVolume;

  /// Genes encountered across all runs, stored by enum index.
  final Set<int> seenVectors;
  final Set<int> seenPayloads;
  final Set<int> seenTriggers;
  final Set<int> seenRiders;

  SaveData({
    this.runs = 0,
    this.bestTime = 0,
    this.bestLevel = 0,
    this.bestKills = 0,
    this.deepestGeneration = 0,
    this.totalKills = 0,
    this.soundVolume = 0.85,
    this.musicVolume = 0.55,
    Set<int>? seenVectors,
    Set<int>? seenPayloads,
    Set<int>? seenTriggers,
    Set<int>? seenRiders,
  })  : seenVectors = seenVectors ?? <int>{},
        seenPayloads = seenPayloads ?? <int>{},
        seenTriggers = seenTriggers ?? <int>{},
        seenRiders = seenRiders ?? <int>{};

  int get codexSeen =>
      seenVectors.length + seenPayloads.length + seenTriggers.length + seenRiders.length;

  int get codexTotal =>
      Vector.values.length +
      Payload.values.length +
      Trigger.values.length +
      Rider.values.length;

  /// Folds a genome the player has held into the codex.
  void record(Genome g) {
    seenVectors.add(g.vector.index);
    seenPayloads.add(g.payload.index);
    seenTriggers.add(g.trigger.index);
    for (final r in g.riders.keys) {
      seenRiders.add(r.index);
    }
  }

  /// Whether a run would set a record, without committing it.
  ///
  /// The end-of-run screen has to show "NEW RECORD" before the player has
  /// decided whether to revive, and a revived run is not over yet — so the
  /// check and the commit have to be separable.
  bool wouldImprove({
    required double time,
    required int level,
    required int kills,
    required int generation,
  }) =>
      time > bestTime ||
      level > bestLevel ||
      kills > bestKills ||
      generation > deepestGeneration;

  /// Folds a finished run into the records. Returns true if anything improved,
  /// so the UI can call out a new personal best.
  bool recordRun({
    required double time,
    required int level,
    required int kills,
    required int generation,
  }) {
    runs++;
    totalKills += kills;
    var improved = false;
    if (time > bestTime) {
      bestTime = time;
      improved = true;
    }
    if (level > bestLevel) {
      bestLevel = level;
      improved = true;
    }
    if (kills > bestKills) {
      bestKills = kills;
      improved = true;
    }
    if (generation > deepestGeneration) {
      deepestGeneration = generation;
      improved = true;
    }
    return improved;
  }

  Map<String, dynamic> toJson() => {
        'runs': runs,
        'bestTime': bestTime,
        'bestLevel': bestLevel,
        'bestKills': bestKills,
        'deepestGeneration': deepestGeneration,
        'totalKills': totalKills,
        'soundVolume': soundVolume,
        'musicVolume': musicVolume,
        'seenVectors': seenVectors.toList(),
        'seenPayloads': seenPayloads.toList(),
        'seenTriggers': seenTriggers.toList(),
        'seenRiders': seenRiders.toList(),
      };

  static SaveData fromJson(Map<String, dynamic> j) => SaveData(
        runs: (j['runs'] as num?)?.toInt() ?? 0,
        bestTime: (j['bestTime'] as num?)?.toDouble() ?? 0,
        bestLevel: (j['bestLevel'] as num?)?.toInt() ?? 0,
        bestKills: (j['bestKills'] as num?)?.toInt() ?? 0,
        deepestGeneration: (j['deepestGeneration'] as num?)?.toInt() ?? 0,
        totalKills: (j['totalKills'] as num?)?.toInt() ?? 0,
        // Clamped on read: a corrupt or hand-edited save must not be able to
        // set a level outside the valid range.
        soundVolume: ((j['soundVolume'] as num?)?.toDouble() ?? 0.85).clamp(0.0, 1.0),
        musicVolume: ((j['musicVolume'] as num?)?.toDouble() ?? 0.55).clamp(0.0, 1.0),
        seenVectors: _intSet(j['seenVectors']),
        seenPayloads: _intSet(j['seenPayloads']),
        seenTriggers: _intSet(j['seenTriggers']),
        seenRiders: _intSet(j['seenRiders']),
      );

  /// Drops any index outside the current enum range, so removing or reordering
  /// a gene in a later build cannot crash an existing save.
  static Set<int> _intSet(dynamic v) {
    if (v is! List) return <int>{};
    return v.whereType<num>().map((e) => e.toInt()).where((e) => e >= 0).toSet();
  }

  // --- storage ------------------------------------------------------------

  static Future<SaveData> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return SaveData();
      return SaveData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // A corrupt or incompatible save must never block play.
      return SaveData();
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(toJson()));
    } catch (_) {
      // Losing a record is not worth interrupting the player over.
    }
  }
}
