import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/leaderboard.dart';

/// A scoreboard is never worth interrupting play over: with no backend
/// configured, or with one that is unreachable, every path must degrade
/// quietly rather than throw into the end-of-run screen.
void main() {
  test('an unconfigured build reports unavailable and never throws', () async {
    const board = OfflineLeaderboard();
    expect(board.isAvailable, isFalse);
    expect(await board.top(), isEmpty);
    expect(
      await board.submit(const ScoreEntry(
          name: 'x', time: 1, level: 1, kills: 1, generation: 0)),
      isFalse,
    );
  });

  test('the factory falls back to offline without credentials', () {
    // No --dart-define in a test run, so this must not produce a live client
    // that would try to reach the network from the game loop.
    expect(createLeaderboard().isAvailable, SupabaseLeaderboard.configured);
  });

  test('entries survive a json round trip', () {
    const e = ScoreEntry(
        name: 'maxim', time: 372.5, level: 21, kills: 2642, generation: 7);
    final back = ScoreEntry.fromJson(e.toJson());
    expect(back.name, e.name);
    expect(back.time, e.time);
    expect(back.level, e.level);
    expect(back.kills, e.kills);
    expect(back.generation, e.generation);
  });

  test('a malformed row does not crash the board', () {
    // Rows come from a public table anyone can insert into; a missing or
    // wrongly typed field must not take the screen down.
    final e = ScoreEntry.fromJson({});
    expect(e.name, 'anonymous');
    expect(e.time, 0);
    expect(e.level, 0);

    final blank = ScoreEntry.fromJson({'name': '   ', 'time': 5});
    expect(blank.name, 'anonymous', reason: 'blank names need a fallback');
  });

  test('rank and highlight are attached without mutating the entry', () {
    const e = ScoreEntry(
        name: 'a', time: 10, level: 2, kills: 3, generation: 1);
    final ranked = e.copyWith(rank: 4, isYou: true);
    expect(ranked.rank, 4);
    expect(ranked.isYou, isTrue);
    expect(e.rank, isNull, reason: 'the original must be untouched');
  });

  // The board shows players, not runs. The table holds every run ever posted,
  // including rows from before the game only submitted personal bests.
  group('one row per player', () {
    ScoreEntry e(String name, double time) =>
        ScoreEntry(name: name, time: time, level: 1, kills: 0, generation: 0);

    test('keeps each name only once, at their best time', () {
      final board = bestPerName([
        e('max', 300),
        e('ana', 250),
        e('max', 200),
        e('max', 10),
        e('ana', 5),
      ]);
      expect(board.map((r) => r.name), ['max', 'ana']);
      expect(board.first.time, 300, reason: 'the best run must be the one kept');
      expect(board.map((r) => r.rank), [1, 2],
          reason: 'ranks must be contiguous after collapsing duplicates');
    });

    test('treats names as one player regardless of case', () {
      final board = bestPerName([e('Max', 300), e('max', 250)]);
      expect(board, hasLength(1),
          reason: 'case variants would otherwise farm duplicate rows');
    });

    test('respects the limit after collapsing, not before', () {
      final board = bestPerName([
        e('a', 100), e('a', 90), e('a', 80),
        e('b', 70), e('c', 60), e('d', 50),
      ], limit: 3);
      expect(board.map((r) => r.name), ['a', 'b', 'c']);
    });

    test('an empty board stays empty', () {
      expect(bestPerName(const []), isEmpty);
    });
  });
}
