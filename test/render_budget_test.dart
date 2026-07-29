import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/rng.dart';
import 'package:splice/src/game/entities.dart';
import 'package:splice/src/game/world.dart';
import 'package:splice/src/genome/genome.dart';
import 'package:splice/src/render/atlas.dart';
import 'package:splice/src/render/renderer.dart';

/// The whole scene is two draw calls, so the only thing that can quietly get
/// expensive is how many sprites go into them.
///
/// The backdrop is the trap: a lattice's cost grows with the square of how
/// fine it is, so halving the spacing quadruples the sprites, and it happens
/// far from anything that looks like a performance decision.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpriteAtlas atlas;
  setUpAll(() async => atlas = await SpriteAtlas.load());

  int drawOnce(World world, ui.Size size) {
    final renderer = Renderer(atlas);
    final recorder = ui.PictureRecorder();
    // Recording only — no rasterisation, so this runs headless.
    renderer.draw(ui.Canvas(recorder), world, size, TouchController());
    recorder.endRecording().dispose();
    return renderer.opaqueSprites + renderer.additiveSprites;
  }

  test('an empty world costs only the backdrop', () {
    final world = World(1);
    world.abilities.clear();
    final total = drawOnce(world, const ui.Size(1920, 1080));
    expect(total, lessThan(1400),
        reason: 'the backdrop alone is already most of a frame — a finer '
            'lattice is a performance decision, not a visual one');
  });

  test('a full late-run frame stays within budget', () {
    final world = World(2);
    final rng = Rng(5);
    while (world.abilities.length < 6) {
      world.addAbility(Genome.wild(rng, power: 12));
    }
    for (var i = 0; i < 400; i++) {
      final e = world.enemyPool.obtain();
      if (e == null) break;
      e.spawn(enemyDefs['crawler']!, rng.range(-500, 500), rng.range(-400, 400),
          i % 4, 3);
    }
    for (var i = 0; i < 120; i++) {
      world.pendingLevelUps = 0;
      world.update(1 / 60);
    }

    final total = drawOnce(world, const ui.Size(1920, 1080));
    expect(total, lessThan(6000),
        reason: 'a busy frame is queueing more sprites than the batch was '
            'sized for');
  });

  test('every creature carries a shadow', () {
    final bare = World(3)..abilities.clear();
    final empty = drawOnce(bare, const ui.Size(1280, 720));

    final withMobs = World(3)..abilities.clear();
    for (var i = 0; i < 10; i++) {
      withMobs.enemyPool.obtain()!.spawn(
          enemyDefs['crawler']!, i * 12.0, 0, 0, 1);
    }
    final populated = drawOnce(withMobs, const ui.Size(1280, 720));

    // Ten creatures, each a body and a shadow.
    expect(populated - empty, greaterThanOrEqualTo(20),
        reason: 'creatures are being drawn without their contact shadow');
  });
}
