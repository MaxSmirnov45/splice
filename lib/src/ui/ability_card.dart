import 'package:flutter/material.dart';

import '../genome/genes.dart';
import '../genome/genome.dart';
import '../render/atlas.dart';
import 'sigil.dart';

/// Shared visual language for the game's interface.
///
/// Named [Skin] rather than the more obvious `Ink` because Flutter's Material
/// library already exports an `Ink` widget.
class Skin {
  static const bg = Color(0xFF05060D);
  static const panel = Color(0xFF0C0F1A);
  static const line = Color(0xFF1E2436);
  static const text = Color(0xFFD8E2EC);
  static const dim = Color(0xFF7A8699);
  static const accent = Color(0xFF3CE0DC);
  static const warn = Color(0xFFF6605A);

  static const mono = 'Menlo';

  static TextStyle label({
    double size = 11,
    Color color = dim,
    FontWeight weight = FontWeight.w500,
  }) => TextStyle(
    fontFamily: mono,
    fontSize: size,
    color: color,
    fontWeight: weight,
    letterSpacing: 0.8,
  );
}

/// Centres overlay content and caps its width, with vertical scrolling when
/// the window is short.
///
/// A full-width column reads fine on a phone and absurd in a 1920px desktop
/// browser; a fixed-height column simply overflows in landscape. Both matter
/// once the game is playable on the web.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  static const double maxWidth = 560;

  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// One ability, shown as a card: sigil, name, trigger, and the three numbers
/// that actually drive a decision.
class AbilityCard extends StatelessWidget {
  final Genome genome;
  final SpriteAtlas atlas;
  final bool selected;
  final bool dimmed;
  final VoidCallback? onTap;

  /// Optional corner badge, e.g. "NEW" or a parent marker.
  final String? badge;

  const AbilityCard({
    super.key,
    required this.genome,
    required this.atlas,
    this.selected = false,
    this.dimmed = false,
    this.onTap,
    this.badge,
  });

  List<Color> get _ramp {
    final key = payloadDefs[genome.payload]!.key;
    return atlas.palettes[atlas.payloadPalette[key] ?? 'bone']!;
  }

  @override
  Widget build(BuildContext context) {
    final ramp = _ramp;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: selected ? ramp[1].withValues(alpha: 0.35) : Skin.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? ramp[3] : Skin.line,
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: ramp[3].withValues(alpha: 0.28),
                    blurRadius: 14,
                  ),
                ]
              : null,
        ),
        child: Opacity(
          opacity: dimmed ? 0.35 : 1.0,
          child: Row(
            children: [
              SigilTile(genome: genome, ramp: ramp, size: 46),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            genome.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Skin.label(
                              size: 12.5,
                              color: ramp[4],
                              weight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (badge != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: ramp[2].withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              badge!,
                              style: Skin.label(size: 8, color: ramp[4]),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      genome.trigger == Trigger.timer
                          ? genome.payloadLabel
                          : '${genome.payloadLabel} · ${genome.triggerLabel}',
                      style: Skin.label(size: 9.5),
                    ),
                    const SizedBox(height: 5),
                    // The rules of the ability, spelled out. Without this a
                    // conditional trigger just looks like a skill that
                    // sometimes refuses to work.
                    Text(
                      genome.description,
                      // Large enough to read on a phone at arm's length, and
                      // bright enough not to sink into the card. The rules of
                      // an ability are not fine print.
                      style: Skin.label(size: 11.5, color: Skin.text)
                          .copyWith(height: 1.45),
                    ),
                    const SizedBox(height: 6),
                    _StatRow(genome: genome, ramp: ramp),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The numbers a player actually compares: output, rate, and how many
/// instances go out per activation.
class _StatRow extends StatelessWidget {
  final Genome genome;
  final List<Color> ramp;

  const _StatRow({required this.genome, required this.ramp});

  @override
  Widget build(BuildContext context) {
    // Scaled down rather than wrapped: four figures on a 320px phone would
    // otherwise clip, and a second line would shift every card's height as
    // numbers grow across a run.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          _stat('DPS', genome.dps.toStringAsFixed(0)),
          _stat('DMG', genome.damage.toStringAsFixed(0)),
          _stat('RATE', '${(1 / genome.cooldown).toStringAsFixed(1)}/s'),
          if (genome.count > 1) _stat('×', '${genome.count}'),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Padding(
    padding: const EdgeInsets.only(right: 11),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text('$label ', style: Skin.label(size: 8, color: Skin.dim)),
        Text(
          value,
          style: Skin.label(size: 11, color: ramp[3], weight: FontWeight.w700),
        ),
      ],
    ),
  );
}

/// Lists the rider stacks carried by a genome, so the player can see what a
/// splice actually inherited.
class RiderStrip extends StatelessWidget {
  final Genome genome;
  final List<Color> ramp;

  const RiderStrip({super.key, required this.genome, required this.ramp});

  @override
  Widget build(BuildContext context) {
    if (genome.riders.isEmpty) {
      return Text('no riders', style: Skin.label(size: 9));
    }
    final entries = genome.riders.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Wrap(
      spacing: 5,
      runSpacing: 4,
      children: [
        for (final e in entries)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: ramp[1].withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: ramp[2].withValues(alpha: 0.5)),
            ),
            child: Text(
              '${riderDefs[e.key]!.name} ${e.value}',
              style: Skin.label(size: 9, color: ramp[3]),
            ),
          ),
      ],
    );
  }
}
