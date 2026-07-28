import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/leaderboard.dart';
import 'package:splice/src/core/save.dart';
import 'package:splice/src/game/splice_game.dart';
import 'package:splice/src/ui/game_screen.dart';

/// The overlays a run can raise are painted in a Stack, and a Stack paints its
/// last child on top. The game-over screen used to be last, so the name prompt
/// opened *underneath* it: present in the tree, findable by every text finder,
/// and completely unreachable by the player.
///
/// The prompt is now raised when the player leaves the run rather than the
/// moment they die — dying is not the end of a run when a revive is on offer,
/// and the prompt covered that offer outright.
///
/// That is why this asserts a real tap lands rather than that the widget
/// exists. `find.text` is satisfied by a widget buried under an opaque panel.
///
/// Only one GameScreen can be booted per test file — Flame's asset cache
/// resolves once per isolate and later mounts never complete — so this file
/// spends its single boot on the assertion that matters.
class _Board implements Leaderboard {
  final List<ScoreEntry> submitted = [];

  @override
  bool get isAvailable => true;

  @override
  Future<List<ScoreEntry>> top({int limit = 100}) async => const [];

  @override
  Future<bool> submit(ScoreEntry entry) async {
    submitted.add(entry);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // There is no audio plugin in a headless test. Stubbed rather than left to
  // throw: the game already treats a failed audio init as non-fatal, but the
  // async MissingPluginException lands mid-test and is reported as a failure
  // that has nothing to do with what is being checked.
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in const [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(channel), (call) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(
          MethodChannel(channel), null));
    }
  });

  /// Swallows the plugin's own async complaints.
  ///
  /// Installed inside the test body rather than in setUp: testWidgets replaces
  /// the error handler when the body starts, so anything set earlier is gone
  /// by the time the exception arrives.
  void ignorePluginErrors() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is MissingPluginException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  testWidgets('the name prompt is reachable over the game-over screen',
      (tester) async {
    ignorePluginErrors();
    final board = _Board();
    final save = SaveData();

    await tester.pumpWidget(MaterialApp(
      home: GameScreen(save: save, onExit: () {}, leaderboard: board),
    ));

    SpliceGame? game;
    for (var i = 0; i < 40 && game == null; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final surface = find.byType(GameWidget<SpliceGame>);
      if (surface.evaluate().isNotEmpty) {
        final g = tester.widget<GameWidget<SpliceGame>>(surface).game!;
        if (g.bootComplete) game = g;
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
    }
    expect(game, isNotNull, reason: 'the game never finished loading');

    // A run worth posting: only a personal best reaches the board, and a
    // fresh save has no best, so this just has to be non-zero.
    game!.state.time = 120;
    game.state.hp = 0;
    game.state.gameOver = true;
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(find.text('CONSUMED'), findsOneWidget, reason: 'the run must end');
    expect(find.text('POST YOUR RUN'), findsNothing,
        reason: 'dying is not the end of a run — the revive offer comes first');

    // Walking away from the run is what settles the score.
    await tester.tap(find.text('SPLICE AGAIN'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('POST YOUR RUN'), findsOneWidget,
        reason: 'a player leaving the run must be asked for a name');

    // The real assertion. A tap that gets swallowed by an overlay above the
    // prompt reports a hit-test miss, which is exactly the bug.
    await tester.enterText(find.byType(TextField), 'maxim');
    await tester.tap(find.text('POST'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(board.submitted, hasLength(1),
        reason: 'tapping POST did not reach the prompt — it is buried under '
            'another overlay');
    expect(board.submitted.single.name, 'maxim');
    expect(save.playerName, 'maxim', reason: 'the name must be remembered');
  });
}
