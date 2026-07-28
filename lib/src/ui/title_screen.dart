import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/leaderboard.dart';
import '../core/rng.dart';
import '../core/save.dart';
import '../genome/genome.dart';
import 'ability_card.dart';
import 'leaderboard_screen.dart';
import 'sigil.dart';

/// Front screen: identity, records, and one button.
///
/// The drifting sigils in the background are generated live from random
/// genomes, which is both the cheapest possible title art and an honest
/// preview of what the game is about.
class TitleScreen extends StatefulWidget {
  final SaveData save;
  final VoidCallback onPlay;

  /// Overridable so a test can drive the board without a live backend.
  final Leaderboard? leaderboard;

  const TitleScreen({
    super.key,
    required this.save,
    required this.onPlay,
    this.leaderboard,
  });

  @override
  State<TitleScreen> createState() => _TitleScreenState();
}

class _TitleScreenState extends State<TitleScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _t = 0;

  late final Leaderboard _leaderboard =
      widget.leaderboard ?? createLeaderboard();
  bool _showBoard = false;

  void _openBoard() => setState(() => _showBoard = true);

  late final List<_Drifter> _drifters;

  static const _ramp = [
    Color(0xFF03101A),
    Color(0xFF0A3A4D),
    Color(0xFF1682A0),
    Color(0xFF3CE0DC),
    Color(0xFFC8FFFA),
  ];

  @override
  void initState() {
    super.initState();
    final rng = Rng(20260727);
    _drifters = List.generate(7, (i) {
      return _Drifter(
        genome: Genome.wild(rng, power: rng.rangeInt(0, 14)),
        x: rng.range(0.05, 0.95),
        y: rng.range(0.05, 0.95),
        speed: rng.range(0.008, 0.028),
        phase: rng.range(0, math.pi * 2),
        size: rng.range(30, 62),
      );
    });
    _ticker = createTicker((elapsed) {
      if (!mounted) return;
      setState(() => _t = elapsed.inMilliseconds / 1000.0);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final save = widget.save;
    final size = MediaQuery.sizeOf(context);

    return Scaffold(
      backgroundColor: Skin.bg,
      body: Stack(
        children: [
          for (final d in _drifters)
            Positioned(
              left:
                  d.x * size.width +
                  math.sin(_t * d.speed * 6 + d.phase) * 26 -
                  d.size / 2,
              top:
                  d.y * size.height +
                  math.cos(_t * d.speed * 5 + d.phase) * 30 -
                  d.size / 2,
              child: Opacity(
                opacity: 0.16,
                child: SigilTile(
                  genome: d.genome,
                  ramp: _ramp,
                  size: d.size,
                  pulse: _t * 0.1 + d.phase,
                ),
              ),
            ),
          // Scrolls and caps its width so a short landscape window or a wide
          // desktop browser both stay readable.
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'SPLICE',
                  textAlign: TextAlign.center,
                  style: Skin.label(
                    size: 52,
                    color: Skin.text,
                    weight: FontWeight.w700,
                  ).copyWith(letterSpacing: 12),
                ),
                const SizedBox(height: 10),
                Text(
                  'BREED YOUR ABILITIES.\nTHE SWARM IS BREEDING TOO.',
                  textAlign: TextAlign.center,
                  style: Skin.label(
                    size: 10,
                    color: Skin.dim,
                  ).copyWith(height: 1.9),
                ),
                const SizedBox(height: 34),
                if (save.runs > 0) _records(save),
                const SizedBox(height: 22),
                _playButton(),
                // The board was previously only reachable from the pause menu
                // and the game-over screen, which is nowhere a player looks
                // for it. It belongs on the front door.
                if (_leaderboard.isAvailable) ...[
                  const SizedBox(height: 10),
                  _secondaryButton('LEADERBOARD', _openBoard),
                ],
                const SizedBox(height: 12),
                Text(
                  save.runs == 0
                      ? 'drag anywhere to move · abilities fire themselves'
                      : 'codex ${save.codexSeen}/${save.codexTotal} genes · ${save.runs} runs',
                  textAlign: TextAlign.center,
                  style: Skin.label(size: 9, color: Skin.dim),
                ),
              ],
            ),
          ),
          if (_showBoard)
            LeaderboardScreen(
              leaderboard: _leaderboard,
              onClose: () => setState(() => _showBoard = false),
            ),
        ],
      ),
    );
  }

  Widget _records(SaveData save) {
    final minutes = (save.bestTime ~/ 60).toString().padLeft(2, '0');
    final seconds = (save.bestTime % 60).floor().toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: Skin.panel.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Skin.line),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _record('BEST', '$minutes:$seconds'),
          _record('LEVEL', '${save.bestLevel}'),
          _record('LINEAGE', 'G${save.deepestGeneration}'),
          _record('KILLS', '${save.totalKills}'),
        ],
      ),
    );
  }

  Widget _record(String label, String value) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        value,
        style: Skin.label(size: 15, color: Skin.text, weight: FontWeight.w700),
      ),
      const SizedBox(height: 3),
      Text(label, style: Skin.label(size: 8, color: Skin.dim)),
    ],
  );

  Widget _secondaryButton(String label, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: 46,
      decoration: BoxDecoration(
        color: Skin.panel.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Skin.line),
      ),
      child: Center(
        child: Text(
          label,
          style: Skin.label(
            size: 12,
            color: Skin.text,
            weight: FontWeight.w700,
          ).copyWith(letterSpacing: 3),
        ),
      ),
    ),
  );

  Widget _playButton() => GestureDetector(
    onTap: widget.onPlay,
    child: Container(
      height: 58,
      decoration: BoxDecoration(
        color: Skin.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Skin.accent, width: 2),
        boxShadow: [
          BoxShadow(color: Skin.accent.withValues(alpha: 0.22), blurRadius: 22),
        ],
      ),
      child: Center(
        child: Text(
          'BEGIN',
          style: Skin.label(
            size: 16,
            color: Skin.accent,
            weight: FontWeight.w700,
          ).copyWith(letterSpacing: 4),
        ),
      ),
    ),
  );
}

class _Drifter {
  final Genome genome;
  final double x, y, speed, phase, size;

  const _Drifter({
    required this.genome,
    required this.x,
    required this.y,
    required this.speed,
    required this.phase,
    required this.size,
  });
}
