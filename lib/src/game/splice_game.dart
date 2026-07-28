import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/game.dart';

import '../core/audio.dart';
import '../core/rng.dart';
import '../genome/genes.dart' as genes;
import '../genome/genome.dart';
import '../render/atlas.dart';
import '../render/renderer.dart';
import 'entities.dart' show EnemyDef, enemyDefs;
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

  /// Scripted showcase, for recording a store video.
  ///
  /// A run played honestly does not reach anything worth filming inside twenty
  /// seconds, and a portal video is judged on its first two. This builds a
  /// late-game organism outright, cycles it through loadouts that look nothing
  /// like each other, and keeps the screen full.
  static const bool trailerMode = bool.fromEnvironment('SPLICE_TRAILER');

  /// How much faster than real time the trailer runs.
  static const double trailerSpeed = 1.5;

  /// Seconds each loadout stays on screen.
  static const double trailerActSeconds = 4.5;

  static const int trailerActs = 4;

  double _trailerClock = 0;
  int _trailerAct = -1;

  /// Which loadout is showing, so the caption can follow it.
  int get trailerAct => _trailerAct < 0 ? 0 : _trailerAct;
  double get trailerClock => _trailerClock;

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
  /// Set by the screen so the game can read keyboard steering.
  KeyboardController? keys;
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

    if (trailerMode) {
      state.level = 24;
      state.time = 540;
      state.maxHp = 260;
      state.hp = 260;
      _showcaseLoadout(0);
    } else if (demoMode) {
      _seedDemoAbilities();
    }

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
  /// Runs the scripted showcase: kiting, loadout changes, and enough pressure
  /// to keep the frame busy.
  void _driveTrailer(double dt) {
    // Two frequencies, so the path is a wandering loop rather than a circle —
    // a perfect orbit reads as a machine driving, which it is.
    state.inputX = math.cos(_trailerClock * 1.15);
    state.inputY = math.sin(_trailerClock * 0.83);

    // Never allowed to die mid-recording, and never interrupted by a level-up.
    state.hp = state.maxHp;
    state.invulnerable = math.max(state.invulnerable, 0.5);

    final act = (_trailerClock / trailerActSeconds).floor() % trailerActs;
    if (act != _trailerAct) {
      _trailerAct = act;
      _showcaseLoadout(act);
    }

    // The spawner alone is too polite for a trailer.
    _trailerSpawnTimer -= dt;
    if (_trailerSpawnTimer <= 0) {
      _trailerSpawnTimer = 0.12;
      _seedTrailerWave();
    }
  }

  double _trailerSpawnTimer = 0;

  /// Four organisms that look nothing like each other.
  ///
  /// The pitch is that no two runs produce the same thing, so one evolved
  /// loadout held for the whole video would undersell it.
  void _showcaseLoadout(int act) {
    const vectors = <List<genes.Vector>>[
      [genes.Vector.orbit, genes.Vector.aura, genes.Vector.bolt],
      [genes.Vector.beam, genes.Vector.chain, genes.Vector.swarm],
      [genes.Vector.wave, genes.Vector.burst, genes.Vector.mine],
      [genes.Vector.tether, genes.Vector.swarm, genes.Vector.beam],
    ];
    const payloads = <List<genes.Payload>>[
      [genes.Payload.frost, genes.Payload.shock, genes.Payload.kinetic],
      [genes.Payload.burn, genes.Payload.voidp, genes.Payload.bleed],
      [genes.Payload.corrode, genes.Payload.frost, genes.Payload.burn],
      [genes.Payload.shock, genes.Payload.bleed, genes.Payload.voidp],
    ];
    final vs = vectors[act];
    final ps = payloads[act];
    final rng = state.rng;

    state.abilities.clear();
    for (var i = 0; i < vs.length; i++) {
      state.addAbility(Genome(
        vector: vs[i],
        // A secondary vector on each, so every ability on screen is visibly a
        // hybrid rather than a starting gene.
        subVector: vs[(i + 1) % vs.length],
        payload: ps[i],
        subPayload: ps[(i + 2) % ps.length],
        trigger: genes.Trigger.timer,
        riders: {
          genes.Rider.amplify: 7 + i * 2,
          genes.Rider.rapid: 6,
          genes.Rider.split: 3 + i,
          genes.Rider.pierce: 4,
          genes.Rider.seek: 5,
          genes.Rider.reach: 3,
          genes.Rider.bloom: 3,
          genes.Rider.echo: 3,
        },
        generation: 5,
        seed: rng.rangeInt(0, 1 << 30),
      ));
    }
  }

  void _seedTrailerWave() {
    const fodder = ['crawler', 'spiker', 'weaver', 'mote', 'floater'];
    final rng = state.rng;
    for (var i = 0; i < 3; i++) {
      final e = state.enemyPool.obtain();
      if (e == null) return;
      final a = rng.range(0, math.pi * 2);
      final r = state.viewHalfWidth + rng.range(30, 140);
      e.spawn(genes_enemy(fodder[rng.rangeInt(0, fodder.length)]),
          state.px + math.cos(a) * r, state.py + math.sin(a) * r,
          rng.rangeInt(0, 4), 2.5);
    }
    // The occasional heavy, for silhouette variety.
    if (rng.chance(0.08)) {
      final e = state.enemyPool.obtain();
      if (e == null) return;
      final a = rng.range(0, math.pi * 2);
      final r = state.viewHalfWidth + 110;
      e.spawn(genes_enemy(rng.chance(0.5) ? 'brute' : 'lancer'),
          state.px + math.cos(a) * r, state.py + math.sin(a) * r, 0, 2.5);
    }
  }

  EnemyDef genes_enemy(String name) => enemyDefs[name]!;

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

    if (trailerMode) {
      dt *= trailerSpeed;
      _trailerClock += dt;
      _driveTrailer(dt);
    } else if (demoMode) {
      _demoClock += dt;
      // A slow orbit keeps the player circling through the swarm rather than
      // standing still, which is what a screenshot needs to look alive.
      state.inputX = math.cos(_demoClock * 0.9);
      state.inputY = math.sin(_demoClock * 0.9);
    } else if (keys != null && keys!.active) {
      // Keyboard wins while a direction is held; releasing it hands control
      // straight back to the joystick without either needing to be reset.
      state.inputX = keys!.dx;
      state.inputY = keys!.dy;
    } else {
      state.inputX = touch.dx;
      state.inputY = touch.dy;
    }
    state.update(dt);
    // One bounded audio dispatch per frame, after the simulation has finished
    // raising events.
    sfx.flush();

    if (state.pendingLevelUps > 0) {
      if (demoMode || trailerMode) {
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
