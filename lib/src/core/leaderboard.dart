import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// One row on the board.
class ScoreEntry {
  final String name;
  final double time;
  final int level;
  final int kills;
  final int generation;

  /// Server-assigned position, 1-based. Null until the board is fetched.
  final int? rank;

  /// True for the row belonging to this device's most recent submission, so
  /// the player can find themselves in a long list.
  final bool isYou;

  const ScoreEntry({
    required this.name,
    required this.time,
    required this.level,
    required this.kills,
    required this.generation,
    this.rank,
    this.isYou = false,
  });

  factory ScoreEntry.fromJson(Map<String, dynamic> j) => ScoreEntry(
        name: (j['name'] as String?)?.trim().isNotEmpty == true
            ? j['name'] as String
            : 'anonymous',
        time: (j['time'] as num?)?.toDouble() ?? 0,
        level: (j['level'] as num?)?.toInt() ?? 0,
        kills: (j['kills'] as num?)?.toInt() ?? 0,
        generation: (j['generation'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'time': time,
        'level': level,
        'kills': kills,
        'generation': generation,
      };

  ScoreEntry copyWith({int? rank, bool? isYou}) => ScoreEntry(
        name: name,
        time: time,
        level: level,
        kills: kills,
        generation: generation,
        rank: rank ?? this.rank,
        isYou: isYou ?? this.isYou,
      );
}

/// A global scoreboard.
///
/// Abstracted so the backend can change without touching the game: a hosted
/// database today, a portal's own leaderboard later if one becomes available.
abstract class Leaderboard {
  /// Whether submissions and fetches can actually reach a server.
  bool get isAvailable;

  /// Top entries, best first. Returns an empty list rather than throwing when
  /// offline — a scoreboard is never worth interrupting play over.
  Future<List<ScoreEntry>> top({int limit = 100});

  /// Submits a finished run. Returns false if it could not be recorded.
  Future<bool> submit(ScoreEntry entry);
}

/// Used when no backend is configured. Everything degrades to "unavailable",
/// and the UI hides the board rather than showing an error.
class OfflineLeaderboard implements Leaderboard {
  const OfflineLeaderboard();

  @override
  bool get isAvailable => false;

  @override
  Future<List<ScoreEntry>> top({int limit = 100}) async => const [];

  @override
  Future<bool> submit(ScoreEntry entry) async => false;
}

/// Supabase-backed board, talking to PostgREST directly.
///
/// Deliberately plain HTTP rather than the Supabase SDK: the whole interaction
/// is one insert and one ordered select, and the SDK would add a dependency
/// and bundle weight to every platform for no benefit.
///
/// Credentials come from the build, never the repository:
///   --dart-define=SUPABASE_URL=https://xxxx.supabase.co
///   --dart-define=SUPABASE_ANON_KEY=eyJ...
class SupabaseLeaderboard implements Leaderboard {
  static const _url = String.fromEnvironment('SUPABASE_URL');
  static const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Table name in the public schema.
  static const _table = 'scores';

  static bool get configured => _url.isNotEmpty && _anonKey.isNotEmpty;

  @override
  bool get isAvailable => configured;

  Map<String, String> get _headers => {
        'apikey': _anonKey,
        'Authorization': 'Bearer $_anonKey',
        'Content-Type': 'application/json',
      };

  @override
  Future<List<ScoreEntry>> top({int limit = 100}) async {
    if (!configured) return const [];
    try {
      // Ordered by survival time, which is the run's headline number.
      final uri = Uri.parse(
        '$_url/rest/v1/$_table'
        '?select=name,time,level,kills,generation'
        '&order=time.desc&limit=$limit',
      );
      final res = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        debugPrint('leaderboard: fetch failed ${res.statusCode}');
        return const [];
      }
      final rows = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
      return [
        for (var i = 0; i < rows.length; i++)
          ScoreEntry.fromJson(rows[i]).copyWith(rank: i + 1),
      ];
    } catch (e) {
      debugPrint('leaderboard: fetch error ($e)');
      return const [];
    }
  }

  @override
  Future<bool> submit(ScoreEntry entry) async {
    if (!configured) return false;
    try {
      final res = await http
          .post(
            Uri.parse('$_url/rest/v1/$_table'),
            headers: _headers,
            body: jsonEncode(entry.toJson()),
          )
          .timeout(const Duration(seconds: 8));
      final ok = res.statusCode >= 200 && res.statusCode < 300;
      if (!ok) debugPrint('leaderboard: submit failed ${res.statusCode} ${res.body}');
      return ok;
    } catch (e) {
      debugPrint('leaderboard: submit error ($e)');
      return false;
    }
  }
}

Leaderboard createLeaderboard() =>
    SupabaseLeaderboard.configured ? SupabaseLeaderboard() : const OfflineLeaderboard();
