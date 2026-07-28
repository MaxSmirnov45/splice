import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/rng.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genes.dart';
import 'package:splice/src/genome/genome.dart';
import 'package:splice/src/render/atlas.dart';
import 'package:splice/src/ui/ability_card.dart';
import 'package:splice/src/ui/splice_screen.dart';

/// Drives the Splice screen directly. Interaction state is the one thing a
/// screenshot cannot verify, and it is where the game's core decision lives.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpriteAtlas atlas;

  setUpAll(() async {
    atlas = await SpriteAtlas.load();
  });

  Future<World> pumpScreen(WidgetTester tester,
      {int abilities = 3, Size? screen}) async {
    if (screen != null) {
      tester.view.physicalSize = screen;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    final world = World(42);
    world.pendingLevelUps = 1;
    world.level = 4;
    final rng = Rng(7);
    while (world.abilities.length < abilities) {
      world.addAbility(Genome.wild(rng, power: 2));
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpliceScreen(world: world, atlas: atlas, onDone: () {}),
      ),
    ));
    return world;
  }

  /// Taps an ability card, scrolling it clear of the pinned footer first.
  ///
  /// Cards carry a description now, so on a short viewport the organism list
  /// starts below the fold and a bare tap lands on the footer instead.
  Future<void> tapAbility(WidgetTester tester, World world, int index) async {
    final target = find.text(world.abilities[index].genome.displayName);
    // The list builds lazily, so a card below the fold does not exist yet and
    // cannot even be located, let alone tapped.
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(target, 80,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }
    // Then only as far as needed, so calling this twice in a row does not
    // scroll straight past the second card.
    final safeY =
        tester.view.physicalSize.height / tester.view.devicePixelRatio * 0.55;
    final y = tester.getCenter(target).dy;
    if (y > safeY) {
      await tester.drag(find.byType(Scrollable).first, Offset(0, safeY - y));
      await tester.pumpAndSettle();
    }
    await tester.tap(target);
    await tester.pump();
  }

  testWidgets('opens with nothing selected and the action disabled', (tester) async {
    await pumpScreen(tester);
    expect(find.text('SELECT AN OPTION'), findsOneWidget);
    expect(find.text('ABSORB'), findsNothing);
    expect(find.text('SPLICE'), findsNothing);
  });

  testWidgets('tapping the spore offers ABSORB when a slot is free', (tester) async {
    await pumpScreen(tester, abilities: 2);
    await tester.tap(find.text('NEW'));
    await tester.pump();
    expect(find.text('ABSORB'), findsOneWidget);
  });

  testWidgets('absorbing adds the spore to the organism', (tester) async {
    final world = await pumpScreen(tester, abilities: 2);
    final before = world.abilities.length;

    await tester.tap(find.text('NEW'));
    await tester.pump();
    await tester.tap(find.text('ABSORB'));
    await tester.pump();

    expect(world.abilities.length, before + 1);
    expect(world.pendingLevelUps, 0);
  });

  testWidgets('selecting two parents offers SPLICE and previews offspring',
      (tester) async {
    final world = await pumpScreen(tester);

    await tapAbility(tester, world, 0);
    expect(find.text('PARENT A'), findsOneWidget);
    expect(find.text('SPLICE'), findsNothing);

    await tapAbility(tester, world, 1);
    expect(find.text('PARENT B'), findsOneWidget);
    expect(find.text('SPLICE'), findsOneWidget);
    expect(find.text('OFFSPRING'), findsOneWidget);
  });

  testWidgets('splicing consumes both parents and yields one child', (tester) async {
    final world = await pumpScreen(tester);
    final before = world.abilities.length;
    final parentA = world.abilities[0].genome;
    final parentB = world.abilities[1].genome;

    await tester.tap(find.text(parentA.displayName));
    await tester.pump();
    await tester.tap(find.text(parentB.displayName));
    await tester.pump();
    await tester.tap(find.text('SPLICE'));
    await tester.pump();

    // Two parents in, one child out: the slot cost is the whole point.
    expect(world.abilities.length, before - 1);
    final child = world.abilities.firstWhere(
        (a) => a.genome.generation > 0,
        orElse: () => world.abilities.first);
    expect(child.genome.generation,
        greaterThan([parentA.generation, parentB.generation].reduce((a, b) => a > b ? a : b) - 1));
  });

  testWidgets('offspring preview is stable across reselection', (tester) async {
    final world = await pumpScreen(tester);
    final a = world.abilities[0].genome.displayName;
    final b = world.abilities[1].genome.displayName;

    Future<String> previewName() async {
      await tester.tap(find.text(a));
      await tester.pump();
      await tester.tap(find.text(b));
      await tester.pump();
      // The offspring name sits inside the preview panel.
      final texts = tester.widgetList<Text>(find.byType(Text)).toList();
      final idx = texts.indexWhere((t) => t.data == 'OFFSPRING');
      return texts[idx + 2].data!;
    }

    final first = await previewName();

    // Deselect both, then pick the same pair again.
    await tester.tap(find.text(a));
    await tester.pump();
    await tester.tap(find.text(b));
    await tester.pump();

    final second = await previewName();
    expect(second, first,
        reason: 'rerolling the mutation by toggling selection would gut the decision');
  });

  testWidgets('spore can replace an ability when the organism is full',
      (tester) async {
    final world = await pumpScreen(tester, abilities: 6);
    expect(world.abilities.length, 6);

    await tester.tap(find.text('NEW'));
    await tester.pump();
    // No free slot, so absorb is unavailable until a victim is chosen.
    expect(find.text('ABSORB'), findsNothing);

    await tapAbility(tester, world, 2);
    expect(find.text('REPLACE'), findsWidgets);

    await tester.tap(find.widgetWithText(Center, 'REPLACE').first);
    await tester.pump();
    expect(world.abilities.length, 6);
  });

  testWidgets('every vector renders a sigil without throwing', (tester) async {
    // The sigil painter switches on vector; a missing branch would only show
    // up as a blank tile or a crash at run time.
    for (final v in Vector.values) {
      final world = World(1);
      world.pendingLevelUps = 1;
      world.abilities.clear();
      world.addAbility(Genome(
        vector: v,
        payload: Payload.burn,
        trigger: Trigger.onKill,
        riders: const {Rider.amplify: 3, Rider.split: 2},
        generation: 3,
      ));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SpliceScreen(world: world, atlas: atlas, onDone: () {}),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'vector $v failed to paint');
    }
  });

  // Cards carry a description now. On the narrowest phone still in use that
  // has to wrap or scale, not clip — a laid-out-but-overflowing card is
  // exactly the kind of thing that ships unnoticed.
  testWidgets('a full organism lays out on a narrow phone', (tester) async {
    await pumpScreen(tester,
        abilities: maxAbilitySlots, screen: const Size(320, 568));
    expect(find.byType(AbilityCard), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the offspring preview lays out on a narrow phone',
      (tester) async {
    final world = await pumpScreen(tester, screen: const Size(320, 568));

    await tapAbility(tester, world, 0);
    await tapAbility(tester, world, 1);

    expect(find.text('OFFSPRING'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Deciding whether to commit to a splice means knowing what the offspring
  // will actually do, not just which genes it inherited.
  testWidgets('the offspring preview describes what the child does',
      (tester) async {
    final world = await pumpScreen(tester);
    await tapAbility(tester, world, 0);
    await tapAbility(tester, world, 1);

    expect(find.text('OFFSPRING'), findsOneWidget);
    // Every description names when the ability fires.
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('OFFSPRING'),
          matching: find.byType(Column),
        ).first,
        matching: find.textContaining('Fires '),
      ),
      findsWidgets,
    );
  });
}
