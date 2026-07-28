import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/leaderboard.dart';
import 'package:splice/src/core/rng.dart';
import 'package:splice/src/core/save.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genome.dart';
import 'package:splice/src/render/atlas.dart';
import 'package:splice/src/ui/ability_card.dart';
import 'package:splice/src/ui/game_screen.dart';
import 'package:splice/src/ui/splice_screen.dart';
import 'package:splice/src/ui/title_screen.dart';

/// The portal publishes the exact iframe sizes its audience plays at, and
/// requires content to stay legible at every one of them at devicePixelRatio 1.
///
/// The short ones are what catch a game out: 821 x 462 leaves 462 logical
/// pixels of height for a screen that has to hold a title, five statistics and
/// four buttons.
const sizes = <(String, Size)>[
  ('desktop 821x462', Size(821, 462)),
  ('desktop 907x510', Size(907, 510)),
  ('desktop 1077x606', Size(1077, 606)),
  ('desktop 1216x684', Size(1216, 684)),
  ('fullscreen 1280x720', Size(1280, 720)),
  ('fullscreen 1366x768', Size(1366, 768)),
  ('fullscreen 1536x864', Size(1536, 864)),
  ('fullscreen 1920x1080', Size(1920, 1080)),
  ('mobile 800x450', Size(800, 450)),
  ('tablet 1080x607', Size(1080, 607)),
];

class _Board implements Leaderboard {
  @override
  bool get isAvailable => true;
  @override
  Future<List<ScoreEntry>> top({int limit = 100}) async => const [];
  @override
  Future<bool> submit(ScoreEntry entry) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpriteAtlas atlas;
  setUpAll(() async => atlas = await SpriteAtlas.load());

  Future<void> at(WidgetTester tester, Size size, Widget child) async {
    // devicePixelRatio 1, as the requirement specifies — a higher ratio would
    // hide overflow that real players at this size would see.
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: child));
    await tester.pump();
  }

  World worldWith(int abilities) {
    final world = World(9);
    world.spawningEnabled = false;
    final rng = Rng(4);
    while (world.abilities.length < abilities) {
      world.addAbility(Genome.wild(rng, power: 6));
    }
    world.pendingLevelUps = 1;
    world.level = 14;
    world.time = 754;
    world.kills = 2318;
    return world;
  }

  for (final (label, size) in sizes) {
    testWidgets('the title screen fits at $label', (tester) async {
      await at(tester, size,
          TitleScreen(save: SaveData()..runs = 12, onPlay: () {}, leaderboard: _Board()));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the end of a run fits at $label', (tester) async {
      // Every optional element present at once: the revive offer, a record,
      // and the leaderboard note. Fewer of them is never the tighter case.
      await at(
        tester,
        size,
        GameOverScreen(
          world: worldWith(6),
          onRestart: () {},
          onExit: () {},
          newBest: true,
          posted: true,
          postedAs: 'a-long-enough-name',
          postable: true,
          onViewBoard: () {},
          onReviveForAd: () {},
        ),
      );
      expect(tester.takeException(), isNull);

      // Not just "no overflow was thrown". The panel scrolls, so content past
      // the bottom raises nothing at all — and MENU really was off-screen at
      // the two shortest sizes, reachable only by scrolling a screen nobody
      // expects to scroll.
      for (final label in const [
        'REVIVE',
        'SPLICE AGAIN',
        'LEADERBOARD',
        'MENU',
      ]) {
        final rect = tester.getRect(find.text(label));
        expect(rect.top, greaterThanOrEqualTo(0.0),
            reason: '$label is above the viewport');
        expect(rect.bottom, lessThanOrEqualTo(size.height),
            reason: '$label falls off the bottom — the player sees a button '
                'cut in half');
      }
    });

    testWidgets('the splice screen fits at $label', (tester) async {
      final world = worldWith(maxAbilitySlots);
      await at(tester, size,
          SpliceScreen(world: world, atlas: atlas, onDone: () {}));
      // With two parents chosen, which pins the offspring preview above the
      // footer and is the tallest this screen ever gets.
      await tester.tap(find.byType(AbilityCard).at(1));
      await tester.pump();
      final cards = find.byType(AbilityCard);
      if (cards.evaluate().length > 2) {
        await tester.tap(cards.at(2));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    });
  }
}
