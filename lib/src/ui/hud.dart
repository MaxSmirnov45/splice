import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../game/entities.dart';
import '../game/world.dart';
import '../genome/genes.dart';
import '../render/atlas.dart';
import '../render/renderer.dart' show KeyboardController;
import 'ability_card.dart';
import 'sigil.dart';

/// Whether to show the frame-rate and pool-occupancy readout.
///
/// Also enabled in demo builds so a release-mode profiling run can be read off
/// the screen — debug numbers alone cannot tell you whether a cost is real or
/// just JIT overhead.
const bool showDiagnostics = kDebugMode || bool.fromEnvironment('SPLICE_DEMO');

/// In-run overlay: vitals, progress, equipped abilities, and the swarm's
/// current resistances.
///
/// Rebuilt every frame from a ticker. The subtree is small and the alternative
/// — pushing values through notifiers that change every frame anyway — costs
/// more than it saves.
class Hud extends StatelessWidget {
  final World world;
  final SpriteAtlas atlas;

  /// Smoothed frame rate, shown only in diagnostic builds.
  final double fps;

  /// Worst frame time in the last second, in milliseconds, and how many frames
  /// in that second were slow enough to see. Averages hide stutter; these do
  /// not.
  final double worstMs;

  /// Worst rasterisation time in the last second. Tracked separately because
  /// the UI and raster threads stall independently.
  final double worstRasterMs;

  final int jank;

  /// Whether the audio backend actually loaded. Shown because "the game is
  /// silent" is otherwise indistinguishable from "the volume is down".
  final bool audioReady;

  /// Keyboard steering, for diagnosing input that does not arrive.
  final KeyboardController? keys;

  const Hud({
    super.key,
    required this.world,
    required this.atlas,
    this.fps = 60,
    this.worstMs = 0,
    this.worstRasterMs = 0,
    this.jank = 0,
    this.audioReady = true,
    this.keys,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Column(
                children: [
                  _xpBar(),
                  const SizedBox(height: 7),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Expanded, not Flexible-plus-Spacer. A Spacer competes
                      // for the same flex space as its siblings, so both sides
                      // could still demand more width than the row had and
                      // overflow. Expanded hands each side a hard allocation.
                      Expanded(child: _vitals()),
                      const SizedBox(width: 8),
                      // Right inset clears the pause button, which sits above
                      // this row in the stack and outside the HUD subtree.
                      Padding(
                        padding: const EdgeInsets.only(right: 40),
                        child: _resistances(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Spacer(),
            if (world.adaptNoticeTime > 0) _adaptBanner(),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: _abilityBar(),
            ),
          ],
        ),
      ),
    );
  }

  // --- pieces -------------------------------------------------------------

  Widget _xpBar() {
    final frac = (world.xp / world.xpToNext).clamp(0.0, 1.0);
    return SizedBox(
      height: 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Stack(
          children: [
            Container(color: Skin.line),
            FractionallySizedBox(
              widthFactor: frac,
              child: Container(
                decoration: BoxDecoration(
                  color: Skin.accent,
                  boxShadow: [
                    BoxShadow(
                      color: Skin.accent.withValues(alpha: 0.6),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _vitals() {
    final minutes = (world.time ~/ 60).toString().padLeft(2, '0');
    final seconds = (world.time % 60).floor().toString().padLeft(2, '0');
    final hpFrac = (world.hp / world.maxHp).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$minutes:$seconds',
              style: Skin.label(
                size: 19,
                color: Skin.text,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'LV${world.level}',
              style: Skin.label(size: 10, color: Skin.accent),
            ),
            const SizedBox(width: 8),
            Text(
              '${world.kills}',
              style: Skin.label(size: 10, color: Skin.dim),
            ),
          ],
        ),
        // Diagnostics get their own line. Inline they pushed the vitals row
        // past the screen width and Flutter reported an overflow.
        if (showDiagnostics) _diagnostics(),
        const SizedBox(height: 4),
        // Health reads as a bar rather than a number: it has to be parseable
        // in peripheral vision while dodging.
        SizedBox(
          width: 116,
          height: 7,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3.5),
            child: Stack(
              children: [
                Container(color: Skin.panel),
                FractionallySizedBox(
                  widthFactor: hpFrac,
                  child: Container(
                    color: hpFrac > 0.35 ? const Color(0xFF6FE38A) : Skin.warn,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Frame timings and pool occupancy, on their own line.
  ///
  /// `u` and `r` are the worst UI-thread and raster-thread frames in the last
  /// second; they are tracked separately because those threads stall
  /// independently and an average across either one hides real stutter.
  Widget _diagnostics() {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      // Scales down rather than overflowing. The readout grows as counters
      // gain digits, so no fixed layout can be guaranteed to fit.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!audioReady)
              Text(
                'MUTE ',
                style: Skin.label(
                  size: 9,
                  color: Skin.warn,
                  weight: FontWeight.w700,
                ),
              ),
            Text(
              '${fps.round()}fps ',
              style: Skin.label(
                size: 9,
                color: fps < 45 ? Skin.warn : Skin.dim,
              ),
            ),
            Text(
              'u${worstMs.round()}/r${worstRasterMs.round()}/${jank}j ',
              style: Skin.label(
                size: 9,
                color: jank > 0 ? Skin.warn : Skin.dim,
              ),
            ),
            // Pool occupancy: a count pinned at capacity means a leak, which is
            // far more likely than a genuine need for that many entities.
            Text(
              '${world.liveEnemies}e ${world.shotPool.liveCount}s '
              '${world.particlePool.liveCount}p ',
              style: Skin.label(size: 9, color: Skin.dim),
            ),
            // k<events> <keyboard vector> in<what the simulation received>.
            // Zero events means keys never reach the app; events without a
            // vector means they are being filtered; a vector without matching
            // input means the game is not reading it.
            Text(
              'k${keys?.eventsSeen ?? -1} '
              '${(keys?.dx ?? 0).toStringAsFixed(1)},'
              '${(keys?.dy ?? 0).toStringAsFixed(1)} '
              'in${world.inputX.toStringAsFixed(1)},'
              '${world.inputY.toStringAsFixed(1)}',
              style: Skin.label(
                size: 9,
                color: (keys?.eventsSeen ?? 0) > 0 ? Skin.accent : Skin.warn,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The swarm's adaptation, shown only for payloads that have actually built
  /// up resistance. This is the feedback loop that tells the player their
  /// build is going stale.
  Widget _resistances() {
    final active =
        world.resistance.entries.where((e) => e.value > 0.04).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    if (active.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('RESIST', style: Skin.label(size: 7.5, color: Skin.dim)),
        const SizedBox(height: 3),
        for (final e in active.take(3))
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  payloadDefs[e.key]!.name.toUpperCase(),
                  style: Skin.label(size: 7.5, color: Skin.dim),
                ),
                const SizedBox(width: 4),
                Container(
                  width: 30,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Skin.panel,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: (e.value / World.maxResistance).clamp(
                      0.0,
                      1.0,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: atlas.payloadColor(payloadDefs[e.key]!.key, 3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                SizedBox(
                  width: 20,
                  child: Text(
                    '${(e.value * 100).round()}%',
                    style: Skin.label(size: 7.5, color: Skin.dim),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _adaptBanner() {
    final p = world.lastAdaptedPayload;
    if (p == null) return const SizedBox.shrink();
    final colour = atlas.payloadColor(payloadDefs[p]!.key, 3);
    final fade = (world.adaptNoticeTime / 3.0).clamp(0.0, 1.0);

    return Opacity(
      opacity: fade,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: Skin.bg.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: colour.withValues(alpha: 0.7)),
            ),
            child: Text(
              'THE SWARM ADAPTS TO ${payloadDefs[p]!.name.toUpperCase()}',
              style: Skin.label(
                size: 10,
                color: colour,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _abilityBar() {
    return Row(
      children: [
        for (final a in world.abilities)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _AbilityPip(world: world, atlas: atlas, ability: a),
          ),
        for (var i = world.abilities.length; i < maxAbilitySlots; i++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Skin.line),
              ),
            ),
          ),
      ],
    );
  }
}

/// One equipped ability, with a cooldown sweep so the player can feel the
/// rhythm of their build without reading anything.
class _AbilityPip extends StatelessWidget {
  final World world;
  final SpriteAtlas atlas;
  final Ability ability;

  const _AbilityPip({
    required this.world,
    required this.atlas,
    required this.ability,
  });

  @override
  Widget build(BuildContext context) {
    final key = payloadDefs[ability.genome.payload]!.key;
    final ramp = atlas.palettes[atlas.payloadPalette[key] ?? 'bone']!;
    final ready = (1 - (ability.cooldown / ability.genome.cooldown)).clamp(
      0.0,
      1.0,
    );

    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        // Static: an animated pulse here would invalidate the sigil's paint on
        // every rebuild, and the cooldown sweep below already carries the
        // sense of motion.
        RepaintBoundary(
          child: SigilTile(genome: ability.genome, ramp: ramp, size: 34),
        ),
        Container(
          width: 34 * ready,
          height: 2,
          margin: const EdgeInsets.only(bottom: 2),
          color: ramp[3].withValues(alpha: 0.9),
        ),
      ],
    );
  }
}
