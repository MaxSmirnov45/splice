import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/rng.dart';
import '../genome/genes.dart';
import '../genome/genome.dart';

/// Draws an ability's sigil from its genome.
///
/// Nothing here is authored per ability — the mark is a direct read of the
/// genes, so an offspring visibly inherits its parents' shapes. That is what
/// makes splicing legible: the player can see the lineage rather than having
/// to read a stat block.
///
///   vector     -> the central glyph
///   payload    -> colour ramp
///   trigger    -> the mark orbiting the glyph
///   riders     -> ticks around the rim, one per stack
///   generation -> enclosing rings
class SigilPainter extends CustomPainter {
  final Genome genome;
  final List<Color> ramp;

  /// 0..1 breathing animation, drives a subtle pulse on the core.
  final double pulse;

  const SigilPainter(this.genome, this.ramp, {this.pulse = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2;

    _paintGenerationRings(canvas, c, r);
    _paintRiderTicks(canvas, c, r);

    final sub = genome.subVector;
    if (sub == null) {
      _paintVector(canvas, c, r * 0.52, genome.vector, 1.0);
    } else {
      // A hybrid shows both parents' marks, offset so neither is hidden. This
      // is the whole point of the mechanic being visible at a glance.
      _paintVector(canvas, c.translate(-r * 0.19, -r * 0.19), r * 0.40,
          genome.vector, 1.0);
      _paintVector(canvas, c.translate(r * 0.23, r * 0.23), r * 0.31, sub, 0.72);
    }

    _paintTriggerMark(canvas, c, r * 0.78);
  }

  Paint get _stroke => Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  // --- layers -------------------------------------------------------------

  void _paintGenerationRings(Canvas canvas, Offset c, double r) {
    // One ring per splice, up to five; beyond that the count is carried by the
    // roman numeral in the name and more rings would just be noise.
    final rings = genome.generation.clamp(0, 5);
    for (var i = 0; i < rings; i++) {
      final t = i / math.max(1, rings);
      canvas.drawCircle(
        c,
        r * (0.93 - i * 0.055),
        _stroke
          ..strokeWidth = 0.9
          ..color = ramp[2].withValues(alpha: 0.30 + 0.35 * (1 - t)),
      );
    }
  }

  void _paintRiderTicks(Canvas canvas, Offset c, double r) {
    final total = genome.totalStacks;
    if (total == 0) return;

    // Cap the drawn ticks; past ~24 the rim saturates and reads as a solid
    // ring, which conveys "heavily modified" just as well.
    final drawn = math.min(total, 24);
    final paint = _stroke..strokeWidth = 1.4;

    var index = 0;
    for (final entry in genome.riders.entries) {
      final riderIndex = Rider.values.indexOf(entry.key);
      // Each rider type owns a hue offset so different riders are
      // distinguishable at a glance without a legend.
      final tone = ramp[2 + (riderIndex % 2)];
      for (var s = 0; s < entry.value && index < drawn; s++, index++) {
        final a = (index / drawn) * math.pi * 2 - math.pi / 2;
        final inner = r * 0.98;
        final outer = r * (1.02 + 0.06 * (s.isEven ? 1 : 0.6));
        canvas.drawLine(
          c + Offset(math.cos(a) * inner, math.sin(a) * inner),
          c + Offset(math.cos(a) * outer, math.sin(a) * outer),
          paint..color = tone.withValues(alpha: 0.9),
        );
      }
    }
  }

  /// Draws one vector's glyph. [alpha] fades the secondary mark on a hybrid.
  void _paintVector(Canvas canvas, Offset c, double r, Vector vector, double alpha) {
    final line = _stroke
      ..strokeWidth = 2.0
      ..color = ramp[3].withValues(alpha: alpha);
    final fill = Paint()..color = ramp[4].withValues(alpha: alpha);
    // A translucent disc rather than a blurred one: this painter runs for every
    // ability pip in the HUD on every frame, and a gaussian per pip per frame
    // is not worth a halo nobody looks at.
    final glow = Paint()..color = ramp[3].withValues(alpha: 0.16 * alpha);

    final pulseScale = 1.0 + 0.06 * math.sin(pulse * math.pi * 2);
    final rr = r * pulseScale;

    canvas.drawCircle(c, rr * 0.55, glow);

    switch (vector) {
      case Vector.bolt:
        // A chevron pointing right: directional, single-target.
        final p = Path()
          ..moveTo(c.dx - rr * 0.5, c.dy - rr * 0.6)
          ..lineTo(c.dx + rr * 0.65, c.dy)
          ..lineTo(c.dx - rr * 0.5, c.dy + rr * 0.6);
        canvas.drawPath(p, line);
        canvas.drawCircle(c + Offset(rr * 0.72, 0), 2.2, fill);
        break;

      case Vector.orbit:
        canvas.drawCircle(c, rr * 0.28, fill);
        canvas.drawCircle(c, rr * 0.8, line..strokeWidth = 1.2);
        for (var i = 0; i < 3; i++) {
          final a = (i / 3) * math.pi * 2 + pulse * math.pi * 2;
          canvas.drawCircle(
              c + Offset(math.cos(a) * rr * 0.8, math.sin(a) * rr * 0.8), 2.4, fill);
        }
        break;

      case Vector.aura:
        for (var i = 1; i <= 3; i++) {
          canvas.drawCircle(c, rr * (0.28 * i),
              _stroke..strokeWidth = 1.4
                ..color = ramp[3].withValues(alpha: (1.0 - i * 0.22) * alpha));
        }
        break;

      case Vector.beam:
        canvas.drawLine(c + Offset(-rr * 0.85, 0), c + Offset(rr * 0.85, 0),
            line..strokeWidth = 3.0);
        canvas.drawLine(c + Offset(-rr * 0.85, -rr * 0.45),
            c + Offset(-rr * 0.85, rr * 0.45), line..strokeWidth = 2.0);
        break;

      case Vector.mine:
        final p = Path()
          ..moveTo(c.dx, c.dy - rr * 0.75)
          ..lineTo(c.dx + rr * 0.75, c.dy)
          ..lineTo(c.dx, c.dy + rr * 0.75)
          ..lineTo(c.dx - rr * 0.75, c.dy)
          ..close();
        canvas.drawPath(p, line);
        canvas.drawCircle(c, rr * 0.22, fill);
        break;

      case Vector.burst:
        for (var i = 0; i < 8; i++) {
          final a = (i / 8) * math.pi * 2;
          canvas.drawLine(
            c + Offset(math.cos(a) * rr * 0.3, math.sin(a) * rr * 0.3),
            c + Offset(math.cos(a) * rr * 0.9, math.sin(a) * rr * 0.9),
            line..strokeWidth = 1.6,
          );
        }
        canvas.drawCircle(c, rr * 0.22, fill);
        break;

      case Vector.chain:
        final p = Path()..moveTo(c.dx - rr * 0.8, c.dy + rr * 0.4);
        for (var i = 1; i <= 4; i++) {
          p.lineTo(c.dx - rr * 0.8 + rr * 0.4 * i,
              c.dy + (i.isEven ? rr * 0.4 : -rr * 0.4));
        }
        canvas.drawPath(p, line);
        break;

      case Vector.tether:
        canvas.drawCircle(c + Offset(-rr * 0.7, 0), rr * 0.2, fill);
        canvas.drawCircle(c + Offset(rr * 0.7, 0), rr * 0.28, line..strokeWidth = 1.8);
        canvas.drawLine(c + Offset(-rr * 0.5, 0), c + Offset(rr * 0.42, 0),
            line..strokeWidth = 1.6);
        break;

      case Vector.wave:
        for (var i = 1; i <= 3; i++) {
          canvas.drawArc(
            Rect.fromCircle(center: c + Offset(-rr * 0.3, 0), radius: rr * 0.3 * i),
            -math.pi / 2.6,
            math.pi / 1.3,
            false,
            _stroke..strokeWidth = 1.8
              ..color = ramp[3].withValues(alpha: (1.0 - i * 0.2) * alpha),
          );
        }
        break;

      case Vector.swarm:
        // Deterministic scatter keyed off the genome seed, so a given ability
        // always draws the same cluster.
        final rng = Rng(genome.seed ^ 0x51CE);
        for (var i = 0; i < 7; i++) {
          final a = rng.range(0, math.pi * 2);
          final d = rng.range(0.25, 0.85) * rr;
          canvas.drawCircle(c + Offset(math.cos(a) * d, math.sin(a) * d), 2.0, fill);
        }
        break;
    }
  }

  void _paintTriggerMark(Canvas canvas, Offset c, double r) {
    if (genome.trigger == Trigger.timer) return; // the default needs no mark

    final index = Trigger.values.indexOf(genome.trigger);
    // Position around the rim encodes which trigger it is.
    final a = -math.pi / 2 + (index / Trigger.values.length) * math.pi * 2;
    final at = c + Offset(math.cos(a) * r, math.sin(a) * r);

    canvas.drawCircle(at, 4.2, Paint()..color = const Color(0xFF05060D));
    canvas.drawCircle(
        at,
        4.2,
        _stroke
          ..strokeWidth = 1.3
          ..color = ramp[4]);
    canvas.drawCircle(at, 1.6, Paint()..color = ramp[4]);
  }

  @override
  bool shouldRepaint(covariant SigilPainter old) =>
      old.genome != genome || old.pulse != pulse || old.ramp != ramp;
}

/// A sigil sized for a card, with the ability's colour bleeding into the
/// background so a row of abilities reads as a palette at a glance.
class SigilTile extends StatelessWidget {
  final Genome genome;
  final List<Color> ramp;
  final double size;
  final double pulse;

  const SigilTile({
    super.key,
    required this.genome,
    required this.ramp,
    this.size = 56,
    this.pulse = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: ramp[0].withValues(alpha: 0.85),
        border: Border.all(color: ramp[2].withValues(alpha: 0.55)),
      ),
      child: CustomPaint(
        painter: SigilPainter(genome, ramp, pulse: pulse),
        size: Size.square(size),
      ),
    );
  }
}
