import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/game.dart';

import '../core/audio.dart';
import '../core/rng.dart';
import '../genome/genome.dart';
import '../render/atlas.dart';
import '../render/renderer.dart';
import 'world.dart' as sim;

/// Hosts the simulation and the renderer.
///
/// Flame supplies the ticker and surface lifecycle; everything else is hand
/// rolled, because a component tree per entity would cost more than the
/// simulation itself at these counts.
///
/// Note the deliberate naming: [FlameGame] already owns `world`, `ready` and
/// `paused`, so the simulation is exposed as [state] and its pause flag as
/// [uiPaused] to avoid shadowing engine behaviour.
class SpliceGame extends FlameGame {
  /// Drives the player on a scripted path instead of reading the joystick.
  ///
  /// Used only to capture store screenshots, which need the game in motion
  /// with no hands on the device. It is a `const` from the environment, so the
  /// branch is tree-shaken out of an ordinary release build.
  static const bool demoMode = bool.fromEnvironment('SPLICE_DEMO');

  SpliceGame({int? seed, this.enableAudio = true}) : _seed = seed;

  final int? _seed;

  /// Set false in headless tests and benchmarks, where the audio plugin has no
  /// platform implementation.
  final bool enableAudio;
  double _demoClock = 0;

  late final SpriteAtlas atlas;
  late sim.World state;
  late final Renderer renderer;
  final TouchController touch = TouchController();
  final KeyboardController keys = KeyboardController();
  final Sfx sfx = Sfx();

  bool bootComplete = false;

  /// Set while the Splice screen is open, so the simulation holds still.
  bool uiPaused = false;

  /// Raised when the player levels up, for the UI layer to react to.
  void Function()? onLevelUp;
  void Function()? onGameOver;

  /// Raised once assets are loaded and the first frame is drawable, so a web
  /// portal can be told the game is ready to play.
  void Function()? onReady;

  @override
  Future<void> onLoad() async {
    atlas = await SpriteAtlas.load();
    state = sim.World(_seed ?? DateTime.now().microsecondsSinceEpoch & 0x7FFFFFFF);
    state.onSound = sfx.request;
    renderer = Renderer(atlas);
    bootComplete = true;

    if (demoMode) _seedDemoAbilities();

    onReady?.call();

    // Audio loads after the first frame is drawable, so a slow audio session
    // never delays the game appearing.
    if (enableAudio) {
      unawaited(sfx.init().then((_) => sfx.startAmbient()));
    }
  }

  /// Gives the capture build a deep, hybrid loadout immediately.
  ///
  /// Store screenshots should show the game at depth, and it doubles as the
  /// only practical way to eyeball high-tier projectile decoration without
  /// playing for ten minutes.
  void _seedDemoAbilities() {
    final rng = Rng(20260727);
    for (var slot = 0; slot < 3; slot++) {
      // Deep enough to show tier decoration, shallow enough that the swarm
      // survives long enough to appear in a screenshot.
      var g = Genome.wild(rng, power: 4);
      for (var i = 0; i < 3; i++) {
        g = Genome.splice(g, Genome.wild(rng, power: 5), rng);
      }
      if (slot == 0) {
        state.replaceAbility(state.abilities.first, g);
      } else {
        state.addAbility(g);
      }
    }
  }

  /// Demo-only: fills empty slots with wild spores, then splices once full, so
  /// an unattended run keeps evolving and reaches realistic entity counts.
  void _autoResolveLevelUps() {
    final rng = state.rng;
    while (state.pendingLevelUps > 0) {
      state.pendingLevelUps--;
      if (state.abilities.length < 4) {
        state.addAbility(Genome.wild(rng, power: state.level));
      } else {
        final a = state.abilities[rng.rangeInt(0, state.abilities.length)];
        var b = state.abilities[rng.rangeInt(0, state.abilities.length)];
        if (identical(a, b)) {
          b = state.abilities.firstWhere((x) => !identical(x, a), orElse: () => a);
        }
        if (identical(a, b)) break;
        state.spliceAbilities(a, b, Genome.splice(a.genome, b.genome, rng));
      }
    }
  }

  @override
  void onRemove() {
    unawaited(sfx.dispose());
    super.onRemove();
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!bootComplete || uiPaused) return;

    if (demoMode) {
      _demoClock += dt;
      // A slow orbit keeps the player circling through the swarm rather than
      // standing still, which is what a screenshot needs to look alive.
      state.inputX = math.cos(_demoClock * 0.9);
      state.inputY = math.sin(_demoClock * 0.9);
    } else if (keys.active) {
      // Keyboard wins while a direction is held; releasing it hands control
      // straight back to the joystick without either needing to be reset.
      state.inputX = keys.dx;
      state.inputY = keys.dy;
    } else {
      state.inputX = touch.dx;
      state.inputY = touch.dy;
    }
    state.update(dt);
    // One bounded audio dispatch per frame, after the simulation has finished
    // raising events.
    sfx.flush();

    if (state.pendingLevelUps > 0) {
      if (demoMode) {
        // Nobody is holding the device during a capture or profiling run, so
        // the Splice screen would block the run at level 2 forever.
        _autoResolveLevelUps();
      } else {
        onLevelUp?.call();
      }
    }
    if (state.gameOver && !state.gameOverEmitted) {
      state.markGameOverEmitted();
      onGameOver?.call();
    }
  }

  @override
  void render(ui.Canvas canvas) {
    super.render(canvas);
    if (!bootComplete) return;
    renderer.draw(canvas, state, ui.Size(size.x, size.y), touch);
  }

  /// Restarts from scratch, keeping the loaded atlas.
  void restart() {
    state = sim.World(DateTime.now().microsecondsSinceEpoch & 0x7FFFFFFF);
    state.onSound = sfx.request;
    touch.up(touch.pointerId ?? -1);
    uiPaused = false;
  }

}
