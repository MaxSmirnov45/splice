import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/ui/game_screen.dart';

/// A run ends once, so the leaderboard has exactly one chance to ask.
///
/// This file exists because an `onPostScore` callback was threaded all the way
/// into the game-over screen and then never rendered — for a while no finished
/// run could reach the board at all, and nothing caught it.
void main() {
  group('what the end of a run does about the board', () {
    test('nothing at all without a backend', () {
      expect(
        endOfRunAction(boardAvailable: false, playerName: ''),
        EndOfRunAction.nothing,
      );
      expect(
        endOfRunAction(boardAvailable: false, playerName: 'maxim'),
        EndOfRunAction.nothing,
        reason: 'a stored name cannot conjure a backend',
      );
    });

    test('asks for a name the first time', () {
      expect(
        endOfRunAction(boardAvailable: true, playerName: ''),
        EndOfRunAction.askForName,
      );
      expect(
        endOfRunAction(boardAvailable: true, playerName: '   '),
        EndOfRunAction.askForName,
        reason: 'whitespace is not a name',
      );
    });

    test('posts without interrupting once the name is known', () {
      expect(
        endOfRunAction(boardAvailable: true, playerName: 'maxim'),
        EndOfRunAction.postNow,
      );
    });
  });

  group('the game-over screen', () {
    Future<void> pump(
      WidgetTester tester, {
      bool posted = false,
      String postedAs = '',
      VoidCallback? onPostScore,
      VoidCallback? onViewBoard,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: GameOverScreen(
          world: World(1),
          onRestart: () {},
          onExit: () {},
          newBest: false,
          posted: posted,
          postedAs: postedAs,
          onPostScore: onPostScore,
          onViewBoard: onViewBoard,
        ),
      ));
      await tester.pump();
    }

    testWidgets('says so and links to the board once posted', (tester) async {
      var opened = false;
      await pump(tester,
          posted: true, postedAs: 'maxim', onViewBoard: () => opened = true);

      expect(find.textContaining('posted as maxim'), findsOneWidget);
      await tester.tap(find.text('LEADERBOARD'));
      expect(opened, isTrue);
    });

    testWidgets('offers a way back for a player who declined the name prompt',
        (tester) async {
      var pressed = false;
      await pump(tester, onPostScore: () => pressed = true);

      expect(find.text('POST TO LEADERBOARD'), findsOneWidget);
      await tester.tap(find.text('POST TO LEADERBOARD'));
      expect(pressed, isTrue);
    });

    testWidgets('never mentions the board when there is no backend',
        (tester) async {
      await pump(tester);
      expect(find.text('POST TO LEADERBOARD'), findsNothing);
      expect(find.text('LEADERBOARD'), findsNothing);
      expect(find.text('CONSUMED'), findsOneWidget,
          reason: 'the run still ends normally');
    });

    testWidgets('does not offer to post a run it already posted',
        (tester) async {
      await pump(tester, posted: true, postedAs: 'maxim', onViewBoard: () {});
      expect(find.text('POST TO LEADERBOARD'), findsNothing);
    });
  });
}
