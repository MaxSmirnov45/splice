import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/leaderboard.dart';
import 'package:splice/src/core/save.dart';
import 'package:splice/src/ui/title_screen.dart';

/// The board used to be reachable only from the pause menu and the game-over
/// screen — nowhere a player looks for it before playing.
class _FakeBoard implements Leaderboard {
  @override
  final bool isAvailable;

  _FakeBoard({this.isAvailable = true});

  @override
  Future<List<ScoreEntry>> top({int limit = 100}) async => const [
        ScoreEntry(
            name: 'spore', time: record, level: 9, kills: 400, generation: 3,
            rank: 1),
      ];

  static const double record = 372.0;

  @override
  Future<bool> submit(ScoreEntry entry) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester, Leaderboard board) async {
    await tester.pumpWidget(MaterialApp(
      home: TitleScreen(save: SaveData(), onPlay: () {}, leaderboard: board),
    ));
    await tester.pump();
  }

  testWidgets('the title screen offers the board and opens it', (tester) async {
    await pump(tester, _FakeBoard());
    expect(find.text('LEADERBOARD'), findsOneWidget);

    await tester.tap(find.text('LEADERBOARD'));
    // Pumped rather than settled: the title screen animates continuously, so
    // it never reaches a quiescent state.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.text('spore'), findsOneWidget);
  });

  testWidgets('no button when no backend is configured', (tester) async {
    await pump(tester, _FakeBoard(isAvailable: false));
    expect(find.text('LEADERBOARD'), findsNothing);
  });
}
