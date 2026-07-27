import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart';

import '../core/ads.dart';
import '../core/save.dart';
import '../game/game_input.dart';
import '../game/splice_game.dart';
import 'ability_card.dart';
import 'hud.dart';
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
class GameScreen extends StatefulWidget {
  final SaveData save;
  final VoidCallback onExit;

  const GameScreen({super.key, required this.save, required this.onExit});

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _input = GameInput(
      onEscape: () {
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

  Future<void> _restart() async {
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
    });
    _ads.gameplayStart();
  }

  void _quitToMenu() {
    _recordRun();
    _ads.gameplayStop();
    widget.onExit();
  }

  bool get _inputBlocked => _showSplice || _showGameOver || _showPause;

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
              ),
            if (_showSplice)
              SpliceScreen(
                world: _game.state,
                atlas: _game.atlas,
                onDone: _closeSplice,
              ),
            if (_showGameOver)
              _GameOverScreen(
                game: _game,
                onRestart: _restart,
                onExit: _quitToMenu,
                newBest: _newBest,
                // Offered only when a revive remains and an ad is actually
                // loaded, so the button never appears and then fails.
                onReviveForAd:
                    _game.state.canRevive && _ads.isReady && !_watchingAd
                    ? _reviveForAd
                    : null,
                watchingAd: _watchingAd,
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

  const _PauseScreen({
    required this.game,
    required this.save,
    required this.onResume,
    required this.onRestart,
    required this.onExit,
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
                size: 28,
                color: Skin.text,
                weight: FontWeight.w700,
              ).copyWith(letterSpacing: 6),
            ),
            const SizedBox(height: 28),
            _row('SURVIVED', '$minutes:$seconds'),
            _row('LEVEL', '${world.level}'),
            _row('KILLS', '${world.kills}'),
            _row('ABILITIES', '${world.abilities.length}/6'),
            const SizedBox(height: 24),
            _volumeSlider('MUSIC', sfx.musicVolume, (v) {
              sfx.setMusicVolume(v);
              widget.save.musicVolume = v;
              setState(() {});
            }),
            const SizedBox(height: 8),
            _volumeSlider('SOUND', sfx.soundVolume, (v) {
              sfx.setSoundVolume(v);
              widget.save.soundVolume = v;
              setState(() {});
            }),
            const SizedBox(height: 22),
            _button('RESUME', Skin.accent, widget.onResume),
            const SizedBox(height: 10),
            _button('RESTART', Skin.dim, widget.onRestart),
            const SizedBox(height: 10),
            _button('MENU', Skin.dim, widget.onExit),
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

  Widget _button(String label, Color colour, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: colour, width: 2),
          ),
          child: Center(
            child: Text(
              label,
              style: Skin.label(
                size: 14,
                color: colour,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
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

class _GameOverScreen extends StatelessWidget {
  final SpliceGame game;
  final VoidCallback onRestart;
  final VoidCallback onExit;
  final bool newBest;
  final VoidCallback? onReviveForAd;
  final bool watchingAd;

  const _GameOverScreen({
    required this.game,
    required this.onRestart,
    required this.onExit,
    required this.newBest,
    this.onReviveForAd,
    this.watchingAd = false,
  });

  @override
  Widget build(BuildContext context) {
    final world = game.state;
    final minutes = (world.time ~/ 60).toString().padLeft(2, '0');
    final seconds = (world.time % 60).floor().toString().padLeft(2, '0');

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
                size: 30,
                color: Skin.warn,
                weight: FontWeight.w700,
              ),
            ),
            if (newBest) ...[
              const SizedBox(height: 8),
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
            const SizedBox(height: 26),
            _row('SURVIVED', '$minutes:$seconds'),
            _row('LEVEL', '${world.level}'),
            _row('KILLS', '${world.kills}'),
            _row('DEEPEST LINEAGE', 'generation ${world.deepestGeneration}'),
            _row('GENOMES HELD', '${world.heldGenomes.length}'),
            const SizedBox(height: 30),
            if (onReviveForAd != null || watchingAd) ...[
              _reviveButton(),
              const SizedBox(height: 10),
            ],
            _button('SPLICE AGAIN', Skin.accent, onRestart),
            const SizedBox(height: 10),
            _button('MENU', Skin.dim, onExit),
          ],
        ),
      ),
    );
  }

  /// Continue-for-an-ad. Kept visually distinct from the plain buttons so it
  /// reads as the offer it is rather than a normal menu option.
  Widget _reviveButton() {
    const green = Color(0xFF6FE38A);
    return GestureDetector(
      onTap: watchingAd ? null : onReviveForAd,
      child: Container(
        height: 58,
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

  Widget _button(String label, Color colour, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: colour, width: 2),
          ),
          child: Center(
            child: Text(
              label,
              style: Skin.label(
                size: 14,
                color: colour,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
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
