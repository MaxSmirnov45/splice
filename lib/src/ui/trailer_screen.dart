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

  @override
  void initState() {
    super.initState();
    _game = SpliceGame();
    _surface = GameWidget(game: _game);
    _ticker = createTicker((elapsed) {
      if (!mounted) return;
      setState(() => _t = elapsed.inMicroseconds / 1e6);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
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
    final opacity = _captionOpacity(intoPhase, phase.seconds);
    final flash = booted ? _game.trailerFlash : 0.0;

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
}
