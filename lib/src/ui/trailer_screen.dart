import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../game/splice_game.dart';
import 'ability_card.dart';

/// The game running as a store trailer, for screen recording.
///
/// Not a video file. Encoding one offline would mean rasterising frames
/// outside a running app, which Flutter will not do — `Picture.toImage` never
/// completes without a frame pipeline attached. Recording the real thing is
/// also simply better: it is genuinely the game, at the real frame rate, in
/// whatever format the recorder produces.
///
///   flutter run -d macos --release --dart-define=SPLICE_TRAILER=true
///
/// Then size the window and record it.
class TrailerScreen extends StatefulWidget {
  const TrailerScreen({super.key});

  @override
  State<TrailerScreen> createState() => _TrailerScreenState();
}

class _TrailerScreenState extends State<TrailerScreen>
    with SingleTickerProviderStateMixin {
  late final SpliceGame _game;
  late final Widget _surface;
  late final Ticker _ticker;
  double _t = 0;

  /// Armed rather than running from launch, so the take can start on cue —
  /// begin the screen recording first, then press START.
  _Stage _stage = _Stage.idle;

  /// Wall-clock second the countdown or the take began.
  double _stageStart = 0;

  /// Seconds of countdown after START, so there is time to let go of the mouse
  /// before the first frame anyone will see.
  static const double countdown = 3;

  @override
  void initState() {
    super.initState();
    _game = SpliceGame();
    _surface = GameWidget(game: _game);
    _game.uiPaused = true;
    _ticker = createTicker((elapsed) {
      if (!mounted) return;
      setState(() {
        _t = elapsed.inMicroseconds / 1e6;
        _advance();
      });
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// Moves the take through its stages.
  void _advance() {
    switch (_stage) {
      case _Stage.idle:
      case _Stage.done:
        break;
      case _Stage.counting:
        if (_t - _stageStart >= countdown) {
          _stage = _Stage.running;
          _stageStart = _t;
          _game
            ..restartTrailer()
            ..uiPaused = false;
        }
      case _Stage.running:
        if (_game.trailerFinished) {
          _stage = _Stage.done;
          _game.uiPaused = true;
        }
    }
  }

  void _start() {
    setState(() {
      _stage = _Stage.counting;
      _stageStart = _t;
      _game.uiPaused = true;
    });
  }

  /// 0 while a caption is arriving, 1 while it holds, 0 as it leaves.
  double _captionOpacity(double intoPhase, double phaseSeconds) {
    const fade = 0.5;
    if (intoPhase < fade) return intoPhase / fade;
    if (intoPhase > phaseSeconds - fade) {
      return ((phaseSeconds - intoPhase) / fade).clamp(0.0, 1.0);
    }
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final booted = _game.bootComplete;
    final phase = SpliceGame.trailerPhases[booted ? _game.trailerPhase : 0];
    final intoPhase = booted ? _game.trailerIntoPhase : 0.0;
    final running = _stage == _Stage.running;
    final opacity = running ? _captionOpacity(intoPhase, phase.seconds) : 0.0;
    final flash = running && booted ? _game.trailerFlash : 0.0;

    return Scaffold(
      backgroundColor: Skin.bg,
      body: Stack(
        children: [
          Positioned.fill(child: _surface),
          // Captions sit low, clear of the health bar and the ability row, and
          // clear of the top-left where portals put their own labels.
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.sizeOf(context).height * 0.13,
            child: IgnorePointer(
              child: Opacity(opacity: opacity, child: _caption(phase.caption)),
            ),
          ),
          // The wordmark rides above the action for the whole run.
          Positioned(
            left: 0,
            right: 0,
            top: MediaQuery.sizeOf(context).height * 0.08,
            child: IgnorePointer(
              child: Opacity(
                opacity: opacity * 0.9,
                child: Text(
                  'SPLICE',
                  textAlign: TextAlign.center,
                  style: _titleStyle(context),
                ),
              ),
            ),
          ),
          // The cut. Painted over everything, including the captions, so the
          // whole frame blooms at once rather than the text surviving it.
          if (flash > 0.001)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(color: Colors.white.withValues(alpha: flash)),
              ),
            ),
          // Everything below is for the person recording and never appears in
          // the take itself.
          if (_stage == _Stage.idle) _readyOverlay(),
          if (_stage == _Stage.counting) _countdownOverlay(),
          if (_stage == _Stage.done) _doneOverlay(),
        ],
      ),
    );
  }

  TextStyle _titleStyle(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return TextStyle(
      // Futura on macOS, where this is recorded; the fallbacks keep it legible
      // anywhere else rather than dropping to a serif.
      fontFamily: 'Futura',
      fontFamilyFallback: const ['Helvetica Neue', 'Menlo'],
      fontSize: w * 0.055,
      letterSpacing: w * 0.022,
      fontWeight: FontWeight.w500,
      color: Colors.white,
      shadows: const [
        Shadow(color: Color(0xCC05060D), blurRadius: 24),
        Shadow(color: Color(0x8805060D), blurRadius: 8),
      ],
    );
  }

  Widget _caption(String text) {
    final w = MediaQuery.sizeOf(context).width;
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: 'Futura',
        fontFamilyFallback: const ['Helvetica Neue', 'Menlo'],
        fontSize: w * 0.028,
        letterSpacing: w * 0.006,
        fontWeight: FontWeight.w600,
        color: const Color(0xFFFFD95E),
        shadows: const [
          Shadow(color: Color(0xDD05060D), blurRadius: 22),
          Shadow(color: Color(0xAA05060D), blurRadius: 6),
        ],
      ),
    );
  }

  Widget _readyOverlay() => _panel(
    title: 'READY TO RECORD',
    lines: const [
      'Start your screen recording first,',
      'then press START.',
      '',
      'One take runs 18 seconds and stops by itself.',
    ],
    action: 'START',
    onTap: _start,
  );

  Widget _countdownOverlay() {
    final left = (countdown - (_t - _stageStart)).ceil().clamp(1, 9);
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xE605060D),
        child: Center(child: Text('$left', style: _titleStyle(context))),
      ),
    );
  }

  Widget _doneOverlay() => _panel(
    title: 'TAKE COMPLETE',
    lines: const [
      'Stop the recording now.',
      '',
      'Press START for another take.',
    ],
    action: 'START AGAIN',
    onTap: _start,
  );

  Widget _panel({
    required String title,
    required List<String> lines,
    required String action,
    required VoidCallback onTap,
  }) {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xF205060D),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: _titleStyle(context).copyWith(fontSize: 34)),
              const SizedBox(height: 22),
              for (final line in lines)
                Text(
                  line,
                  textAlign: TextAlign.center,
                  style: Skin.label(
                    size: 13,
                    color: Skin.dim,
                  ).copyWith(height: 1.9),
                ),
              const SizedBox(height: 30),
              GestureDetector(
                onTap: onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 46,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: Skin.accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Skin.accent, width: 2),
                  ),
                  child: Text(
                    action,
                    style: Skin.label(
                      size: 15,
                      color: Skin.accent,
                      weight: FontWeight.w700,
                    ).copyWith(letterSpacing: 3),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where a take is in its life.
enum _Stage { idle, counting, running, done }
