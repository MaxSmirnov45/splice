import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/ui/game_screen.dart';

/// Advertising is switched off entirely during a Basic launch, so every
/// request goes unfilled. Nothing the player touches may depend on one
/// arriving, and nothing may make them wait for one that never will.
void main() {
  testWidgets('the restart button reports that it is working', (tester) async {
    // An interstitial sits between the press and the next run. Left looking
    // idle, the player presses again and again — which is what "it works after
    // about ten clicks" actually was: the first press finally returning.
    var presses = 0;
    Future<void> pump({required bool restarting}) => tester.pumpWidget(
          MaterialApp(
            home: GameOverScreen(
              world: World(1),
              onRestart: () => presses++,
              onExit: () {},
              newBest: false,
              restarting: restarting,
            ),
          ),
        );

    await pump(restarting: false);
    await tester.tap(find.text('SPLICE AGAIN'));
    expect(presses, 1);

    await pump(restarting: true);
    expect(find.text('SPLICE AGAIN'), findsNothing);
    expect(find.text('STARTING…'), findsOneWidget,
        reason: 'a button that looks idle while busy invites mashing');

    await tester.tap(find.text('STARTING…'));
    expect(presses, 1,
        reason: 'a second press must not stack another restart behind '
            'another ad request');
  });
}
