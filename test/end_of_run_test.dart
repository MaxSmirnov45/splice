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
    EndOfRunAction act({
      bool board = true,
      String name = 'maxim',
      double run = 100,
      double best = 0,
    }) => endOfRunAction(
      boardAvailable: board,
      playerName: name,
      runTime: run,
      bestTime: best,
    );

    test('nothing at all without a backend', () {
      expect(act(board: false, name: ''), EndOfRunAction.nothing);
      expect(
        act(board: false),
        EndOfRunAction.nothing,
        reason: 'a stored name cannot conjure a backend',
      );
    });

    test('asks for a name the first time', () {
      expect(act(name: ''), EndOfRunAction.askForName);
      expect(
        act(name: '   '),
        EndOfRunAction.askForName,
        reason: 'whitespace is not a name',
      );
    });

    test('posts without interrupting once the name is known', () {
      expect(act(), EndOfRunAction.postNow);
    });

    // Only the best run belongs on a board ranked by survival time. Four early
    // deaths in a row must not push four dead rows at it.
    test('a run that does not beat your best stays off the board', () {
      expect(act(run: 90, best: 200), EndOfRunAction.notPersonalBest);
      expect(
        act(run: 200, best: 200),
        EndOfRunAction.notPersonalBest,
        reason: 'matching your best is not beating it',
      );
      expect(act(run: 201, best: 200), EndOfRunAction.postNow);
    });

    test('a worse run is not worth asking for a name over', () {
      expect(
        act(name: '', run: 10, best: 200),
        EndOfRunAction.notPersonalBest,
        reason: 'interrupting for a run that will not be posted is rude',
      );
    });
  });

  group('the game-over screen', () {
    Future<void> pump(
      WidgetTester tester, {
      bool posted = false,
      String postedAs = '',
      bool postable = false,
      VoidCallback? onPostScore,
      VoidCallback? onViewBoard,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: GameOverScreen(
            world: World(1),
            onRestart: () {},
            onExit: () {},
            newBest: false,
            posted: posted,
            postedAs: postedAs,
            postable: postable,
            onPostScore: onPostScore,
            onViewBoard: onViewBoard,
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('says so and links to the board once posted', (tester) async {
      var opened = false;
      await pump(
        tester,
        posted: true,
        postedAs: 'maxim',
        postable: true,
        onViewBoard: () => opened = true,
      );

      expect(find.textContaining('posted as maxim'), findsOneWidget);
      await tester.tap(find.text('LEADERBOARD'));
      expect(opened, isTrue);
    });

    testWidgets('offers a way back for a player who declined the name prompt', (
      tester,
    ) async {
      var pressed = false;
      await pump(tester, postable: true, onPostScore: () => pressed = true);

      expect(find.text('POST TO LEADERBOARD'), findsOneWidget);
      await tester.tap(find.text('POST TO LEADERBOARD'));
      expect(pressed, isTrue);
    });

    // A run that quietly does not post is indistinguishable from one that
    // failed to post, which is how the missing-button bug went unnoticed.
    testWidgets('says why a lesser run did not go up', (tester) async {
      await pump(tester, onViewBoard: () {});
      expect(find.textContaining('only your best run'), findsOneWidget);
      expect(
        find.text('LEADERBOARD'),
        findsOneWidget,
        reason: 'the board is still worth a look',
      );
      expect(
        find.text('POST TO LEADERBOARD'),
        findsNothing,
        reason: 'offering to post a run that will be rejected is a lie',
      );
    });

    testWidgets('never mentions the board when there is no backend', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('POST TO LEADERBOARD'), findsNothing);
      expect(find.text('LEADERBOARD'), findsNothing);
      expect(
        find.text('CONSUMED'),
        findsOneWidget,
        reason: 'the run still ends normally',
      );
    });

    testWidgets('does not offer to post a run it already posted', (
      tester,
    ) async {
      await pump(
        tester,
        posted: true,
        postedAs: 'maxim',
        postable: true,
        onViewBoard: () {},
      );
      expect(find.text('POST TO LEADERBOARD'), findsNothing);
    });
  });
}
