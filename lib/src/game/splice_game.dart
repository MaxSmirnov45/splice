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
  /// seconds, and a portal video is judged on its first two. This plays the
  /// arc instead: one plain ability, then a hybrid, then an organism six
  /// generations deep, so the video shows what the game *does* rather than
  /// just what its late game looks like.
  static const bool trailerMode = bool.fromEnvironment('SPLICE_TRAILER');

  /// How much faster than real time the trailer runs.
  static const double trailerSpeed = 1.5;

  /// The three acts. Total runs to eighteen seconds, inside the portal's
  /// twenty-second limit with room to spare.
  static const List<TrailerPhase> trailerPhases = [
    TrailerPhase(
      caption: 'EVERY RUN STARTS WITH ONE ABILITY',
      seconds: 5,
      abilities: 1,
      generation: 0,
      riders: 0,
      hybrid: false,
      spawnInterval: 0.5,
      enemyHp: 1.0,
      level: 2,
      time: 35,
    ),
    TrailerPhase(
      caption: 'EVERY LEVEL, BREED TWO INTO ONE',
      seconds: 5,
      abilities: 3,
      generation: 2,
      riders: 3,
      hybrid: true,
      spawnInterval: 0.24,
      enemyHp: 1.8,
      level: 11,
      time: 240,
    ),
    TrailerPhase(
      caption: 'SIX GENERATIONS LATER',
      seconds: 8,
      abilities: 5,
      generation: 6,
      riders: 8,
      hybrid: true,
      spawnInterval: 0.11,
      enemyHp: 3.0,
      level: 27,
      time: 620,
    ),
  ];

  static double get trailerSeconds =>
      trailerPhases.fold(0.0, (sum, p) => sum + p.seconds);

  double _trailerClock = 0;
  int _trailerPhase = -1;

  /// Counts down after a cut. Drives the white flash that hides the moment the
  /// loadout is swapped — without it the organism visibly teleports.
  double _trailerFlash = 0;

  static const double trailerFlashSeconds = 0.42;

  /// Rewinds the showcase to its first frame.
  ///
  /// The recording has to be able to start on cue, so the sequence is armed
  /// rather than simply running from launch.
  void restartTrailer() {
    _trailerClock = 0;
    _trailerFlash = 0;
    _trailerSpawnTimer = 0;
    _trailerPhase = 0;
    _applyPhase(trailerPhases.first, clearField: true);
  }

  /// True once a full pass has played, so the recording has a definite end.
  bool get trailerFinished => _trailerClock >= trailerSeconds;

  int get trailerPhase => _trailerPhase < 0 ? 0 : _trailerPhase;
  double get trailerClock => _trailerClock;

  /// 1 at the instant of a cut, falling to 0. Squared, so the flash blooms
  /// hard and leaves quickly rather than lingering as a grey wash.
  double get trailerFlash {
    final t = (_trailerFlash / trailerFlashSeconds).clamp(0.0, 1.0);
    return t * t;
  }

  /// Seconds spent in the current phase.
  double get trailerIntoPhase {
    var t = _trailerClock % trailerSeconds;
    for (final p in trailerPhases) {
      if (t < p.seconds) return t;
      t -= p.seconds;
    }
    return 0;
  }

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
      _applyPhase(trailerPhases.first, clearField: true);
      _trailerPhase = 0;
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

    if (_trailerFlash > 0) _trailerFlash -= dt;

    // Which act the clock is in.
    var t = _trailerClock % trailerSeconds;
    var index = 0;
    for (var i = 0; i < trailerPhases.length; i++) {
      if (t < trailerPhases[i].seconds) {
        index = i;
        break;
      }
      t -= trailerPhases[i].seconds;
      index = i + 1;
    }
    index = index.clamp(0, trailerPhases.length - 1);

    if (index != _trailerPhase) {
      // Cut on a flash. The loadout is replaced wholesale, and swapping it in
      // plain sight reads as a glitch rather than as progression.
      _trailerFlash = trailerFlashSeconds;
      final looped = index < _trailerPhase;
      _trailerPhase = index;
      _applyPhase(trailerPhases[index], clearField: looped || index == 0);
    }

    final phase = trailerPhases[index];
    _trailerSpawnTimer -= dt;
    if (_trailerSpawnTimer <= 0) {
      _trailerSpawnTimer = phase.spawnInterval;
      _seedTrailerWave(phase);
    }
  }

  /// Rebuilds the organism, and the numbers on the HUD, for one act.
  void _applyPhase(TrailerPhase phase, {bool clearField = false}) {
    state.level = phase.level;
    state.time = phase.time;
    state.maxHp = 100 + phase.level * 6.0;
    state.hp = state.maxHp;

    if (clearField) {
      // Everything, not just the enemies. A cut back to the opening act with
      // the previous act's shots, orbs and dying particles still in flight
      // gives the whole trick away in one frame.
      for (final e in state.enemies) {
        e.alive = false;
      }
      for (final x in state.shots) {
        x.alive = false;
      }
      for (final x in state.threats) {
        x.alive = false;
      }
      for (final x in state.particles) {
        x.alive = false;
      }
      for (final x in state.pickups) {
        x.alive = false;
      }
      for (final x in state.arcs) {
        x.alive = false;
      }
    }
    state.abilities.clear();
    for (final g in _phaseLoadout(phase)) {
      state.addAbility(g);
    }
  }

  double _trailerSpawnTimer = 0;

  /// The organism on show for one act.
  ///
  /// Vectors are drawn from a fixed order so each act looks unlike the last,
  /// and the first act is deliberately plain — a single bolt with no riders,
  /// which is genuinely what a run opens with.
  List<Genome> _phaseLoadout(TrailerPhase phase) {
    const order = <genes.Vector>[
      genes.Vector.bolt,
      genes.Vector.orbit,
      genes.Vector.beam,
      genes.Vector.aura,
      genes.Vector.chain,
      genes.Vector.swarm,
    ];
    const pays = <genes.Payload>[
      genes.Payload.kinetic,
      genes.Payload.frost,
      genes.Payload.burn,
      genes.Payload.shock,
      genes.Payload.voidp,
      genes.Payload.bleed,
    ];
    final rng = state.rng;
    return [
      for (var i = 0; i < phase.abilities; i++)
        Genome(
          vector: order[i % order.length],
          subVector: phase.hybrid ? order[(i + 2) % order.length] : null,
          payload: pays[i % pays.length],
          subPayload: phase.hybrid ? pays[(i + 3) % pays.length] : null,
          trigger: genes.Trigger.timer,
          riders: phase.riders == 0
              ? const {}
              : {
                  genes.Rider.amplify: phase.riders,
                  genes.Rider.rapid: (phase.riders * 0.8).round(),
                  genes.Rider.split: (phase.riders * 0.5).round(),
                  genes.Rider.pierce: (phase.riders * 0.5).round(),
                  genes.Rider.seek: (phase.riders * 0.6).round(),
                  genes.Rider.reach: (phase.riders * 0.4).round(),
                  genes.Rider.bloom: (phase.riders * 0.35).round(),
                  genes.Rider.echo: (phase.riders * 0.35).round(),
                },
          generation: phase.generation,
          seed: rng.rangeInt(0, 1 << 30),
        ),
    ];
  }

  void _seedTrailerWave(TrailerPhase phase) {
    const fodder = ['crawler', 'spiker', 'weaver', 'mote', 'floater'];
    final rng = state.rng;
    for (var i = 0; i < phase.wave; i++) {
      final e = state.enemyPool.obtain();
      if (e == null) return;
      final a = rng.range(0, math.pi * 2);
      final r = state.viewHalfWidth + rng.range(30, 140);
      e.spawn(genes_enemy(fodder[rng.rangeInt(0, fodder.length)]),
          state.px + math.cos(a) * r, state.py + math.sin(a) * r,
          rng.rangeInt(0, 4), phase.enemyHp);
    }
    // The occasional heavy, for silhouette variety.
    if (phase.generation >= 2 && rng.chance(0.08)) {
      final e = state.enemyPool.obtain();
      if (e == null) return;
      final a = rng.range(0, math.pi * 2);
      final r = state.viewHalfWidth + 110;
      e.spawn(genes_enemy(rng.chance(0.5) ? 'brute' : 'lancer'),
          state.px + math.cos(a) * r, state.py + math.sin(a) * r, 0,
          phase.enemyHp);
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

/// One act of the trailer.
class TrailerPhase {
  final String caption;
  final double seconds;

  /// How much of an organism the player has by this point.
  final int abilities;
  final int generation;
  final int riders;

  /// Whether each ability carries a second vector and payload — the visible
  /// signature of a splice, and false for the opening act on purpose.
  final bool hybrid;

  /// How hard the swarm presses.
  final double spawnInterval;
  final double enemyHp;

  /// What the HUD reads, so the footage is internally consistent.
  final int level;
  final double time;

  const TrailerPhase({
    required this.caption,
    required this.seconds,
    required this.abilities,
    required this.generation,
    required this.riders,
    required this.hybrid,
    required this.spawnInterval,
    required this.enemyHp,
    required this.level,
    required this.time,
  });

  /// Enemies per wave, scaled with how far into a run this act pretends to be.
  int get wave => generation == 0 ? 1 : (generation >= 6 ? 4 : 2);
}
