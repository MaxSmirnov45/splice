import 'dart:async';

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;

import '../core/ads.dart';
import '../core/leaderboard.dart';
import '../core/save.dart';
import '../game/game_input.dart';
import '../game/splice_game.dart';
import '../game/world.dart';
import 'ability_card.dart';
import 'hud.dart';
import 'leaderboard_screen.dart';
import 'splice_screen.dart';

/// Hosts the game surface, routes raw pointer events into the joystick, and
/// stacks the interface on top.
///
/// Pointer handling deliberately uses a raw [Listener] rather than Flame's
/// gesture mixins: the joystick needs the exact down/move/up stream with
/// pointer identity, and nothing here should ever be lost to a gesture arena.
///
/// The consequence is that the pause button must live *outside* the Listener's
/// subtree. Inside it, tapping pause would also plant the floating joystick at
/// that point and the player would drift while the menu opened.
/// What the end of a run should do about the leaderboard.
enum EndOfRunAction {
  /// No backend, so the board is never mentioned.
  nothing,

  /// The player has been further before. Their better run is already up
  /// there, so this one has nothing to add.
  notPersonalBest,

  /// First run worth posting: ask what name to post under, then post.
  askForName,

  /// The name is already known, so post without interrupting.
  postNow,
}

/// Decides how a finished run reaches the board.
///
/// Pulled out of the widget because getting it wrong is invisible: a run that
/// silently fails to post looks exactly like a run that posted fine, and the
/// board has no update path to correct it afterwards.
///
/// Only a personal best goes up. The board is ranked by survival time, so
/// every lesser run is a row nobody will ever read — and a player who dies
/// early four times in a row should not push four dead entries at it.
EndOfRunAction endOfRunAction({
  required bool boardAvailable,
  required String playerName,
  required double runTime,
  required double bestTime,
}) {
  if (!boardAvailable) return EndOfRunAction.nothing;
  if (runTime <= bestTime) return EndOfRunAction.notPersonalBest;
  return playerName.trim().isEmpty
      ? EndOfRunAction.askForName
      : EndOfRunAction.postNow;
}

class GameScreen extends StatefulWidget {
  final SaveData save;
  final VoidCallback onExit;

  /// Overridable so the end-of-run flow can be driven without a live backend.
  final Leaderboard? leaderboard;

  const GameScreen({
    super.key,
    required this.save,
    required this.onExit,
    this.leaderboard,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with WidgetsBindingObserver {
  late final SpliceGame _game;
  late final Widget _surface;

  bool _showSplice = false;
  bool _showGameOver = false;
  bool _showPause = false;

  /// Set while a rewarded ad is on screen, so the revive button cannot be
  /// tapped twice.
  bool _watchingAd = false;

  late final RewardedAdService _ads;

  /// Whether the run that just ended beat a personal record.
  bool _newBest = false;

  /// Guards against recording the same run twice — a player can reach the
  /// records path by dying, or by quitting from the pause menu.
  bool _runRecorded = false;

  /// Global key routing. Not focus-based — see [GameInput].
  late final GameInput _input;

  late final Leaderboard _leaderboard =
      widget.leaderboard ?? createLeaderboard();
  bool _showBoard = false;
  bool _showNamePrompt = false;

  /// The run just finished, held so it can be posted once a name exists and
  /// highlighted in the board afterwards.
  ScoreEntry? _pendingScore;

  /// Whether the finished run has been sent to the board.
  bool _posted = false;

  /// Whether it is worth sending at all — only a personal best is.
  bool _postable = false;

  /// What to do once the name prompt has been answered, one way or the other.
  VoidCallback? _afterScore;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _input = GameInput(
      onPause: () {
        if (_showPause) {
          _closePause();
        } else if (!_inputBlocked) {
          _openPause();
        }
      },
      blocked: () => _inputBlocked,
    )..install();
    _ads = createAdService();
    // Portals require the game muted and paused for the whole time an ad is on
    // screen, signalled by the ad itself rather than by us requesting one.
    _ads.onAdOpened = () {
      _game.uiPaused = true;
      _game.sfx.pauseAmbient();
    };
    _ads.onAdClosed = () {
      _game.sfx.resumeAmbient();
    };
    // The host's own mute control overrides the player's levels while it is
    // on, and restores exactly those levels when it goes off.
    _ads.onHostMuteChanged = (muted) => _game.sfx.setHostMuted(muted);
    // Fire and forget: a missing or failing ad network simply means the revive
    // option is never offered.
    _ads.initialize();
    _game = SpliceGame()
      ..keys = _input.keys
      ..onLevelUp = _handleLevelUp
      ..onGameOver = _handleGameOver
      ..onReady = () {
        // Tell the host the game is playable, then mark the run as live.
        _ads.loadingFinished();
        _ads.gameplayStart();
      };
    // Seeded before the game loads, so saved levels are applied when the audio
    // players are first configured rather than re-sent afterwards.
    _game.sfx.primeVolumes(
      sound: widget.save.soundVolume,
      music: widget.save.musicVolume,
    );
    // Built once and reused: rebuilding GameWidget would tear down the game.
    _surface = GameWidget(game: _game);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _ads.dispose();
    super.dispose();
  }

  /// Auto-pauses when the app leaves the foreground.
  ///
  /// The ticker stops on its own while backgrounded, so nothing simulates —
  /// but without this the player is dropped straight back into a swarm on
  /// resume, mid-dodge, with no chance to react.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _openPause();
  }

  // --- overlays -----------------------------------------------------------

  void _handleLevelUp() {
    if (_inputBlocked) return;
    _ads.gameplayStop();
    setState(() {
      _showSplice = true;
      _game.uiPaused = true;
      // Drop the joystick, or the player keeps drifting while choosing.
      _game.touch.up(_game.touch.pointerId ?? -1);
    });
  }

  void _handleGameOver() {
    _ads.gameplayStop();
    final world = _game.state;
    // Checked, not committed. The player may still revive, in which case the
    // run continues and must not be banked yet.
    _newBest = widget.save.wouldImprove(
      time: world.time,
      level: world.level,
      kills: world.kills,
      generation: world.deepestGeneration,
    );
    // Compared against the records as they stand: _recordRun folds this run in
    // later, when the player leaves the game-over screen.
    final action = endOfRunAction(
      boardAvailable: _leaderboard.isAvailable,
      playerName: widget.save.playerName,
      runTime: world.time,
      bestTime: widget.save.bestTime,
    );
    _postable =
        action != EndOfRunAction.nothing &&
        action != EndOfRunAction.notPersonalBest;
    _pendingScore = _postable ? _entryForRun() : null;

    // Nothing is posted here, and nothing is asked. Dying is not the end of a
    // run — a revive continues it — so a score banked now could be a truncated
    // one, and the board has no way to correct it afterwards. The prompt also
    // opened straight over this screen, hiding the revive offer the player was
    // being interrupted for. Both are settled in _finishRun, when the player
    // actually walks away from the run.
    setState(() {
      _showPause = false;
      _showGameOver = true;
      _game.uiPaused = true;
    });
  }

  /// Shows a rewarded ad and revives on success.
  Future<void> _reviveForAd() async {
    if (_watchingAd || !_ads.isReady || !_game.state.canRevive) return;
    setState(() => _watchingAd = true);

    // Duck the music for the ad's own audio. Restored in the finally block so
    // it comes back whether the ad completed, was dismissed, or failed to show
    // at all — leaving the game permanently silent after a failed ad would be
    // a miserable bug to track down.
    await _game.sfx.pauseAmbient();

    var earned = false;
    try {
      earned = await _ads.show();
    } finally {
      await _game.sfx.resumeAmbient();
    }
    if (!mounted) return;

    setState(() {
      _watchingAd = false;
      if (earned) {
        _game.state.revive();
        _showGameOver = false;
        _game.uiPaused = false;
        // The run is not over after all, so the score banked when it looked
        // like it was must be thrown away. Posting it now would put a
        // truncated run on the board and, since the board has no update path,
        // it could never be corrected.
        _pendingScore = null;
        _posted = false;
        _postable = false;
        _showNamePrompt = false;
      }
    });
  }

  void _openPause() {
    if (_inputBlocked || !_game.bootComplete) return;
    _ads.gameplayStop();
    setState(() {
      _showPause = true;
      _game.uiPaused = true;
      _game.touch.up(_game.touch.pointerId ?? -1);
    });
  }

  void _closePause() {
    // Write the audio levels once on close rather than on every drag frame —
    // a slider emits changes continuously and each write hits disk.
    widget.save.save();
    _ads.gameplayStart();
    setState(() {
      _showPause = false;
      _game.uiPaused = false;
    });
  }

  void _closeSplice() {
    _ads.gameplayStart();
    setState(() {
      _showSplice = false;
      _game.uiPaused = false;
    });
  }

  // --- run lifecycle ------------------------------------------------------

  /// Folds the current run into the persistent records and codex.
  void _recordRun() {
    if (_runRecorded) return;
    _runRecorded = true;

    final world = _game.state;
    // Everything the player ever held goes into the codex, including genomes
    // that were consumed by a splice along the way.
    for (final g in world.heldGenomes) {
      widget.save.record(g);
    }
    widget.save.recordRun(
      time: world.time,
      level: world.level,
      kills: world.kills,
      generation: world.deepestGeneration,
    );
    // Fire and forget: a failed write must never block the UI.
    widget.save.save();
  }

  /// Settles the leaderboard question, then runs [then].
  ///
  /// Called at the two points a run is genuinely over — starting another, or
  /// leaving — rather than at the moment of death, which a revive can undo.
  void _finishRun(VoidCallback then) {
    if (!_postable || _posted) {
      then();
      return;
    }
    if (widget.save.playerName.trim().isEmpty) {
      // Deferred: the prompt has to resolve before the run can be torn down,
      // or the entry is built from a world that no longer exists.
      _afterScore = then;
      setState(() => _showNamePrompt = true);
      return;
    }
    _posted = true;
    // Not awaited: a slow or failed submission must not delay the next run.
    unawaited(_submitPending());
    then();
  }

  /// Guards the restart against being started twice.
  ///
  /// An interstitial sits between pressing the button and the next run, and an
  /// unfilled request can take seconds to give up. Without this the player
  /// presses again, and again, each press stacking another restart behind
  /// another ad request — which reads as the button working "after about ten
  /// clicks" when what actually happened is that the first one finally
  /// returned.
  bool _restarting = false;

  void _restart() {
    if (_restarting) return;
    _finishRun(() => unawaited(_doRestart()));
  }

  Future<void> _doRestart() async {
    setState(() => _restarting = true);
    // Abandoning a run still banks what the player achieved in it — losing a
    // ten-minute record because you had to quit would be indefensible.
    _recordRun();

    // Between runs is the only place a non-rewarded break belongs. No-op on
    // the app stores, where this game shows no interstitials at all.
    await _game.sfx.pauseAmbient();
    await _ads.commercialBreak();
    await _game.sfx.resumeAmbient();
    if (!mounted) return;

    setState(() {
      _game.restart();
      _showGameOver = false;
      _showSplice = false;
      _showPause = false;
      _newBest = false;
      _runRecorded = false;
      _pendingScore = null;
      _posted = false;
      _postable = false;
      _restarting = false;
    });
    _ads.gameplayStart();
  }

  void _quitToMenu() => _finishRun(() {
    _recordRun();
    _ads.gameplayStop();
    widget.onExit();
  });

  bool get _inputBlocked =>
      _showSplice ||
      _showGameOver ||
      _showPause ||
      _showBoard ||
      _showNamePrompt;

  /// Builds the entry for the run that just ended.
  ScoreEntry _entryForRun() {
    final w = _game.state;
    return ScoreEntry(
      name: widget.save.playerName.isEmpty
          ? 'anonymous'
          : widget.save.playerName,
      time: w.time,
      level: w.level,
      kills: w.kills,
      generation: w.deepestGeneration,
    );
  }

  Future<void> _submitPending() async {
    final entry = _pendingScore;
    if (entry == null) return;
    // Fire and forget as far as the player is concerned: a failed submission
    // must not block them from seeing the board or starting another run.
    await _leaderboard.submit(entry);
  }

  void _openBoard() {
    if (!_game.bootComplete) return;
    _ads.gameplayStop();
    setState(() => _showBoard = true);
  }

  void _closeBoard() {
    setState(() => _showBoard = false);
    if (!_showGameOver) _ads.gameplayStart();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Android back should pause rather than drop the player out of a run.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_showPause) {
          _closePause();
        } else if (!_inputBlocked) {
          _openPause();
        }
      },
      child: Scaffold(
        backgroundColor: Skin.bg,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              behavior: HitTestBehavior.deferToChild,
              onPointerSignal: (e) {
                // Mouse wheel zooms on a laptop, mirroring the pinch gesture.
                if (e is PointerScrollEvent && !_inputBlocked) {
                  setState(() {
                    _game.touch.nudgeZoom(-e.scrollDelta.dy / 500);
                  });
                }
              },
              onPointerDown: (e) {
                if (_inputBlocked) return;
                _game.touch.down(e.pointer, e.localPosition);
              },
              onPointerMove: (e) {
                if (_inputBlocked) return;
                _game.touch.move(e.pointer, e.localPosition);
              },
              onPointerUp: (e) => _game.touch.up(e.pointer),
              onPointerCancel: (e) => _game.touch.up(e.pointer),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _surface,
                  if (!_inputBlocked) _HudOverlay(game: _game),
                ],
              ),
            ),

            // Outside the Listener on purpose — see the class doc.
            if (!_inputBlocked) _PauseButton(onTap: _openPause),

            if (_showPause)
              _PauseScreen(
                game: _game,
                save: widget.save,
                onResume: _closePause,
                onRestart: _restart,
                onExit: _quitToMenu,
                onLeaderboard: _leaderboard.isAvailable
                    ? () {
                        setState(() => _showPause = false);
                        _openBoard();
                      }
                    : null,
              ),
            if (_showSplice)
              SpliceScreen(
                world: _game.state,
                atlas: _game.atlas,
                onDone: _closeSplice,
              ),
            // Ordering here is load-bearing. A Stack paints its last child on
            // top, and the game-over screen used to be last — so the name
            // prompt and the board both opened underneath it and were
            // invisible. Anything the summary can raise must come after it.
            if (_showGameOver)
              GameOverScreen(
                world: _game.state,
                onRestart: _restart,
                onExit: _quitToMenu,
                newBest: _newBest,
                restarting: _restarting,
                posted: _posted,
                postedAs: widget.save.playerName,
                postable: _postable,
                onViewBoard: _leaderboard.isAvailable ? _openBoard : null,
                // Offered only when a revive remains and an ad is actually
                // loaded, so the button never appears and then fails.
                onReviveForAd:
                    _game.state.canRevive && _ads.isReady && !_watchingAd
                    ? _reviveForAd
                    : null,
                watchingAd: _watchingAd,
              ),
            if (_showNamePrompt)
              NamePrompt(
                initial: widget.save.playerName,
                onSubmit: (name) async {
                  widget.save.playerName = name;
                  widget.save.save();
                  final then = _afterScore;
                  _afterScore = null;
                  // Keeps the run captured when the player died — so the
                  // time on the board is the time they died at, not the time
                  // they finished typing — but takes the name they just gave.
                  // Reusing the entry wholesale posted them as "anonymous",
                  // since it was built before a name existed.
                  final run = _pendingScore ?? _entryForRun();
                  _pendingScore = ScoreEntry(
                    name: name,
                    time: run.time,
                    level: run.level,
                    kills: run.kills,
                    generation: run.generation,
                  );
                  setState(() {
                    _showNamePrompt = false;
                    _posted = true;
                  });
                  unawaited(_submitPending());
                  if (then != null) {
                    then();
                  } else if (mounted) {
                    setState(() => _showBoard = true);
                  }
                },
                onSkip: () {
                  final then = _afterScore;
                  _afterScore = null;
                  setState(() => _showNamePrompt = false);
                  // Declining must not trap the player on the run they were
                  // trying to leave.
                  then?.call();
                },
              ),
            if (_showBoard)
              LeaderboardScreen(
                leaderboard: _leaderboard,
                highlight: _pendingScore,
                onClose: _closeBoard,
              ),
          ],
        ),
      ),
    );
  }
}

/// Drives the HUD from its own ticker so per-frame repaints are confined to
/// the overlay and never touch the game surface.
class _HudOverlay extends StatefulWidget {
  final SpliceGame game;

  const _HudOverlay({required this.game});

  @override
  State<_HudOverlay> createState() => _HudOverlayState();
}

class _HudOverlayState extends State<_HudOverlay>
    with SingleTickerProviderStateMixin {
  /// The HUD rebuilds at 20Hz, not 60.
  ///
  /// Nothing on it — a clock in whole seconds, two bars, six cooldown sweeps —
  /// benefits from 60fps, but rebuilding the subtree that often meant
  /// repainting six CustomPaint sigils every frame alongside the game itself.
  static const Duration _rebuildInterval = Duration(milliseconds: 50);

  late final Ticker _ticker;
  Duration _lastBuild = Duration.zero;
  Duration _lastFrame = Duration.zero;
  double _fps = 60;

  /// Worst frame time and jank count over the last second.
  ///
  /// A smoothed average is the wrong metric for perceived smoothness: a run
  /// can average 60fps and still hitch several times a second, which is
  /// exactly what players notice. These two numbers surface that.
  double _worstMs = 0;
  int _jank = 0;
  double _windowWorst = 0;
  int _windowJank = 0;
  Duration _windowStart = Duration.zero;

  /// A frame this long or worse is a visible stutter at 60Hz.
  static const double _jankThresholdMs = 24.0;

  /// Worst rasterisation time in the last second.
  ///
  /// Measured separately from the UI thread because they stall independently.
  /// A ticker only sees the UI thread; if rasterisation is slow — or the
  /// platform thread it may be merged with is blocked, for instance by audio
  /// channel calls — the display stutters while UI-thread timings look
  /// perfect. That mismatch is exactly what made earlier readings misleading.
  double _worstRasterMs = 0;
  double _windowWorstRaster = 0;

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final build = t.buildDuration.inMicroseconds / 1000.0;
      final raster = t.rasterDuration.inMicroseconds / 1000.0;
      if (build > _windowWorst) _windowWorst = build;
      if (raster > _windowWorstRaster) _windowWorstRaster = raster;
      if (build >= _jankThresholdMs || raster >= _jankThresholdMs) {
        _windowJank++;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _ticker = createTicker((elapsed) {
      if (!mounted) return;

      if (_lastFrame != Duration.zero) {
        final ms = (elapsed - _lastFrame).inMicroseconds / 1000.0;
        if (ms > 0.5) _fps = _fps * 0.92 + (1000 / ms) * 0.08;
      }
      _lastFrame = elapsed;

      if (elapsed - _windowStart >= const Duration(seconds: 1)) {
        _windowStart = elapsed;
        _worstMs = _windowWorst;
        _worstRasterMs = _windowWorstRaster;
        _jank = _windowJank;
        _windowWorst = 0;
        _windowWorstRaster = 0;
        _windowJank = 0;
      }

      if (elapsed - _lastBuild < _rebuildInterval) return;
      _lastBuild = elapsed;
      setState(() {});
    })..start();
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.game.bootComplete) return const SizedBox.shrink();
    return Hud(
      world: widget.game.state,
      atlas: widget.game.atlas,
      fps: _fps,
      worstMs: _worstMs,
      worstRasterMs: _worstRasterMs,
      jank: _jank,
      audioReady: widget.game.sfx.isReady,
      keys: widget.game.keys,
    );
  }
}

/// Top-right pause control.
///
/// Deliberately not bottom-right: the floating joystick spawns wherever the
/// thumb lands, and a button in the natural thumb rest position would be hit
/// by accident constantly.
class _PauseButton extends StatelessWidget {
  final VoidCallback onTap;

  const _PauseButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 18, right: 10),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Skin.panel.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Skin.line),
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [_bar(), const SizedBox(width: 4), _bar()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bar() => Container(
    width: 3.5,
    height: 13,
    decoration: BoxDecoration(
      color: Skin.text.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

class _PauseScreen extends StatefulWidget {
  final SpliceGame game;
  final SaveData save;
  final VoidCallback onResume;
  final VoidCallback onRestart;
  final VoidCallback onExit;
  final VoidCallback? onLeaderboard;

  const _PauseScreen({
    required this.game,
    required this.save,
    required this.onResume,
    required this.onRestart,
    required this.onExit,
    this.onLeaderboard,
  });

  @override
  State<_PauseScreen> createState() => _PauseScreenState();
}

class _PauseScreenState extends State<_PauseScreen> {
  @override
  Widget build(BuildContext context) {
    final world = widget.game.state;
    final sfx = widget.game.sfx;
    final minutes = (world.time ~/ 60).toString().padLeft(2, '0');
    final seconds = (world.time % 60).floor().toString().padLeft(2, '0');

    // Same squeeze as the game-over screen: this one carries two sliders on
    // top of the statistics, so it is the taller of the two.
    final tight = Panel.tight(context);

    return Container(
      color: Skin.bg.withValues(alpha: 0.93),
      child: Panel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'PAUSED',
              textAlign: TextAlign.center,
              style: Skin.label(
                size: tight ? 20 : 28,
                color: Skin.text,
                weight: FontWeight.w700,
              ).copyWith(letterSpacing: 6),
            ),
            SizedBox(height: tight ? 12 : 28),
            _row('SURVIVED', '$minutes:$seconds', tight),
            _row('LEVEL', '${world.level}', tight),
            _row('KILLS', '${world.kills}', tight),
            _row('ABILITIES', '${world.abilities.length}/6', tight),
            SizedBox(height: tight ? 12 : 24),
            _volumeSlider('MUSIC', sfx.musicVolume, (v) {
              sfx.setMusicVolume(v);
              widget.save.musicVolume = v;
              setState(() {});
            }),
            SizedBox(height: tight ? 4 : 8),
            _volumeSlider('SOUND', sfx.soundVolume, (v) {
              sfx.setSoundVolume(v);
              widget.save.soundVolume = v;
              setState(() {});
            }),
            SizedBox(height: tight ? 12 : 22),
            _button('RESUME', Skin.accent, widget.onResume, tight),
            SizedBox(height: tight ? 6 : 10),
            _button('RESTART', Skin.dim, widget.onRestart, tight),
            SizedBox(height: tight ? 6 : 10),
            _button('MENU', Skin.dim, widget.onExit, tight),
          ],
        ),
      ),
    );
  }

  /// A labelled level control. Zero is off, so there is no separate mute
  /// button to keep in sync with the slider.
  Widget _volumeSlider(
    String label,
    double value,
    ValueChanged<double> onChanged,
  ) {
    final off = value <= 0.001;
    final tint = off ? Skin.dim : Skin.accent;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      decoration: BoxDecoration(
        color: Skin.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: off ? Skin.line : tint.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: Skin.label(size: 10, color: tint, weight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: tint,
                inactiveTrackColor: Skin.line,
                thumbColor: off ? Skin.dim : Skin.text,
                overlayColor: tint.withValues(alpha: 0.15),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                showValueIndicator: ShowValueIndicator.never,
              ),
              child: Slider(value: value.clamp(0.0, 1.0), onChanged: onChanged),
            ),
          ),
          SizedBox(
            width: 38,
            child: Text(
              off ? 'OFF' : '${(value * 100).round()}',
              textAlign: TextAlign.right,
              style: Skin.label(size: 10, color: Skin.dim),
            ),
          ),
        ],
      ),
    );
  }

  /// A null [onTap] renders the button dimmed and inert.
  Widget _button(
    String label,
    Color colour,
    VoidCallback? onTap, [
    bool tight = false,
  ]) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: tight ? 42 : 52,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colour, width: 2),
      ),
      child: Center(
        child: Text(
          label,
          style: Skin.label(size: 14, color: colour, weight: FontWeight.w700),
        ),
      ),
    ),
  );

  Widget _row(String label, String value, [bool tight = false]) => Padding(
    padding: EdgeInsets.symmetric(vertical: tight ? 3 : 6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: Skin.label(size: 11)),
        Text(
          value,
          style: Skin.label(
            size: 14,
            color: Skin.text,
            weight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

/// Shown when a run ends.
///
/// Takes the [World] it reports on rather than the whole game: it only ever
/// reads the run's numbers, and the narrower dependency lets it be built in a
/// test without loading Flame.
class GameOverScreen extends StatelessWidget {
  final World world;
  final VoidCallback onRestart;
  final VoidCallback onExit;
  final bool newBest;
  final VoidCallback? onReviveForAd;
  final bool watchingAd;

  /// Whether the run has already gone to the board, and under what name.
  final bool posted;
  final String postedAs;

  /// False when the run was not a personal best, so it was never a candidate.
  /// Worth saying out loud — a silent non-post is indistinguishable from a
  /// broken one.
  final bool postable;

  /// Set while the next run is being prepared. An interstitial sits in the
  /// way, so the button has to look busy rather than dead.
  final bool restarting;

  /// Null when no scoreboard backend is configured, in which case nothing
  /// about the board is offered rather than shown and failing.
  final VoidCallback? onViewBoard;

  const GameOverScreen({
    super.key,
    required this.world,
    required this.onRestart,
    required this.onExit,
    required this.newBest,
    this.onReviveForAd,
    this.watchingAd = false,
    this.posted = false,
    this.postedAs = '',
    this.postable = false,
    this.restarting = false,
    this.onViewBoard,
  });

  @override
  Widget build(BuildContext context) {
    final minutes = (world.time ~/ 60).toString().padLeft(2, '0');
    final seconds = (world.time % 60).floor().toString().padLeft(2, '0');
    // At the portal's shortest published sizes the MENU button fell off the
    // bottom of the viewport. Reachable by scrolling, but a reviewer sees a
    // half-cut button, and so does anyone playing un-fullscreened.
    final tight = Panel.tight(context);

    return Container(
      color: Skin.bg.withValues(alpha: 0.95),
      child: Panel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'CONSUMED',
              textAlign: TextAlign.center,
              style: Skin.label(
                size: tight ? 22 : 30,
                color: Skin.warn,
                weight: FontWeight.w700,
              ),
            ),
            if (newBest) ...[
              SizedBox(height: tight ? 4 : 8),
              Text(
                'NEW RECORD',
                textAlign: TextAlign.center,
                style: Skin.label(
                  size: 11,
                  color: Skin.accent,
                  weight: FontWeight.w700,
                ),
              ),
            ],
            SizedBox(height: tight ? 12 : 26),
            _row('SURVIVED', '$minutes:$seconds', tight),
            _row('LEVEL', '${world.level}', tight),
            _row('KILLS', '${world.kills}', tight),
            _row(
              'DEEPEST LINEAGE',
              'generation ${world.deepestGeneration}',
              tight,
            ),
            _row('GENOMES HELD', '${world.heldGenomes.length}', tight),
            SizedBox(height: tight ? 14 : 30),
            if (onReviveForAd != null || watchingAd) ...[
              _reviveButton(tight),
              SizedBox(height: tight ? 6 : 10),
            ],
            _button(
              restarting ? 'STARTING…' : 'SPLICE AGAIN',
              Skin.accent,
              restarting ? null : onRestart,
              tight,
            ),
            SizedBox(height: tight ? 6 : 10),
            if (onViewBoard != null) ...[
              if (_boardNote() != null) ...[
                Text(
                  _boardNote()!,
                  textAlign: TextAlign.center,
                  style: Skin.label(size: 9.5, color: Skin.dim),
                ),
                SizedBox(height: tight ? 5 : 8),
              ],
              _button('LEADERBOARD', Skin.text, onViewBoard!, tight),
              SizedBox(height: tight ? 6 : 10),
            ],
            _button('MENU', Skin.dim, onExit, tight),
          ],
        ),
      ),
    );
  }

  /// What became of this run as far as the board is concerned, or null while
  /// the answer is still open.
  ///
  /// Null rather than "not posted yet" on purpose: at this point the player is
  /// deciding whether to revive, and the run is only posted once they choose
  /// not to. Announcing a pending post would be describing something that may
  /// never happen.
  String? _boardNote() {
    if (posted) {
      return postedAs.isEmpty
          ? 'posted to the leaderboard'
          : 'posted as $postedAs';
    }
    if (!postable) return 'only your best run goes on the board';
    return null;
  }

  /// Continue-for-an-ad. Kept visually distinct from the plain buttons so it
  /// reads as the offer it is rather than a normal menu option.
  Widget _reviveButton([bool tight = false]) {
    const green = Color(0xFF6FE38A);
    return GestureDetector(
      onTap: watchingAd ? null : onReviveForAd,
      child: Container(
        height: tight ? 46 : 58,
        decoration: BoxDecoration(
          color: green.withValues(alpha: watchingAd ? 0.06 : 0.16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: green.withValues(alpha: watchingAd ? 0.4 : 1),
            width: 2,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                watchingAd ? 'LOADING…' : 'REVIVE',
                style: Skin.label(
                  size: 15,
                  color: green,
                  weight: FontWeight.w700,
                ),
              ),
              if (!watchingAd) ...[
                const SizedBox(height: 2),
                Text(
                  'watch an ad · keeps your organism',
                  style: Skin.label(
                    size: 8.5,
                    color: green.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// A null [onTap] renders the button dimmed and inert.
  Widget _button(
    String label,
    Color colour,
    VoidCallback? onTap, [
    bool tight = false,
  ]) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: tight ? 42 : 52,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colour, width: 2),
      ),
      child: Center(
        child: Text(
          label,
          style: Skin.label(size: 14, color: colour, weight: FontWeight.w700),
        ),
      ),
    ),
  );

  Widget _row(String label, String value, [bool tight = false]) => Padding(
    padding: EdgeInsets.symmetric(vertical: tight ? 3 : 7),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: Skin.label(size: 11)),
        Text(
          value,
          style: Skin.label(
            size: 14,
            color: Skin.text,
            weight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}
