import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, KeyUpEvent, LogicalKeyboardKey;

import '../game/entities.dart';
import '../game/world.dart';
import '../genome/genes.dart';
import 'atlas.dart';

/// Draws the world.
///
/// Everything funnels into two batches: an opaque pass for bodies and an
/// additive pass for anything that glows. Two draw calls for the whole scene,
/// regardless of entity count.
class Renderer {
  /// World units of height the camera tries to show. Everything is scaled to
  /// fit this, so the playable area is consistent across screen sizes.
  ///
  /// Larger means more world on screen. Pulled back from 430 so the player can
  /// see threats arriving with enough warning to react, rather than having
  /// them enter the frame already on top of them.
  ///
  /// Note this costs entity count: the simulation keeps the visible area
  /// populated, so widening the view by 20% grows the on-screen swarm by
  /// roughly 40%.
  static const double targetViewHeight = 650;

  final SpriteAtlas atlas;

  final SpriteBatch _opaque = SpriteBatch();
  final SpriteBatch _additive = SpriteBatch();

  final ui.Paint _opaquePaint = ui.Paint()..filterQuality = ui.FilterQuality.none;
  final ui.Paint _additivePaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.none
    ..blendMode = ui.BlendMode.plus;

  static const ui.Color _background = ui.Color(0xFF05060D);

  ui.Shader? _vignette;
  ui.Size _vignetteSize = ui.Size.zero;

  /// Expanding circles (auras, waves, detonations) collected during the entity
  /// passes and stroked after them.
  ///
  /// These cannot go through the atlas: a 30px ring sprite blown up to a 200
  /// unit radius is a blocky mess. Drawn as real circles they stay crisp at
  /// any size, and there are only ever a handful per frame.
  final List<_Ring> _rings = [];

  /// Every atlas rect a payload can need, resolved once at construction.
  ///
  /// The draw loop used to build strings like 'spark_$key' per sprite per
  /// frame. At a few hundred entities that is tens of thousands of throwaway
  /// String allocations a second feeding the garbage collector, for lookups
  /// whose answers never change.
  late final List<_PayloadFrames> _payloadFrames = [
    for (final p in Payload.values) _PayloadFrames.of(atlas, payloadDefs[p]!.key),
  ];

  /// Enemy body rects, indexed by archetype then variant.
  late final Map<String, List<ui.Rect>> _enemyFrames = {
    for (final name in enemyDefs.keys)
      name: [for (var i = 0; i < atlas.variants; i++) atlas.frame('${name}_$i')],
  };

  late final ui.Rect _hostFrame = atlas.frame('host_0');
  late final ui.Rect _dotFrame = atlas.frame('dot_white');
  late final ui.Rect _xpSmallFrame = atlas.frame('xp_small');
  late final ui.Rect _xpLargeFrame = atlas.frame('xp_large');
  late final ui.Rect _healFrame = atlas.frame('heal');

  double scale = 2.0;

  Renderer(this.atlas);

  void draw(ui.Canvas canvas, World world, ui.Size size, TouchController touch) {
    // Base scale fits a consistent slice of the world on any screen; the pinch
    // multiplier lets the player trade visibility for detail.
    // Lower floor than the sprites strictly want, so short screens can still
    // honour the wide default view instead of being clamped back in.
    scale = (size.height / targetViewHeight).clamp(1.1, 4.5) * touch.zoom;

    // Tell the simulation how much it needs to keep populated.
    world.viewHalfWidth = size.width / scale * 0.5;
    world.viewHalfHeight = size.height / scale * 0.5;

    canvas.drawColor(_background, ui.BlendMode.src);

    _opaque.clear();
    _additive.clear();
    _rings.clear();

    canvas.save();
    // Centre the camera on the player, in world units.
    canvas.translate(size.width * 0.5, size.height * 0.5);
    canvas.scale(scale);
    canvas.translate(-world.px, -world.py);

    _drawBackdrop(world);
    _drawAuras(world);
    _drawPickups(world);
    _drawShots(world, under: true);
    _drawEnemies(world);
    _drawPlayer(world);
    _drawShots(world, under: false);
    _drawParticles(world);

    _opaque.render(canvas, atlas.image, _opaquePaint);
    _additive.render(canvas, atlas.image, _additivePaint);

    _flushRings(canvas);
    _drawArcs(canvas, world);
    _drawTethers(canvas, world);
    _drawHealthBars(canvas, world);

    canvas.restore();

    _drawVignette(canvas, size);
    _drawJoystick(canvas, touch);
  }

  // --- layers -------------------------------------------------------------

  /// A faint dot lattice. Without it the player has no sense of motion in an
  /// empty region of an infinite plane.
  void _drawBackdrop(World world) {
    const spacing = 64.0;
    final left = world.px - world.viewHalfWidth - spacing;
    final right = world.px + world.viewHalfWidth + spacing;
    final top = world.py - world.viewHalfHeight - spacing;
    final bottom = world.py + world.viewHalfHeight + spacing;

    final startX = (left / spacing).floor() * spacing;
    final startY = (top / spacing).floor() * spacing;
    final dot = _dotFrame;

    for (var y = startY; y <= bottom; y += spacing) {
      for (var x = startX; x <= right; x += spacing) {
        _opaque.add(dot, x, y, scale: 0.85, color: 0x2A6FA8C0);
      }
    }
  }

  void _drawAuras(World world) {
    for (final a in world.abilities) {
      if (a.genome.vector != Vector.aura) continue;
      final pf = _payloadFrames[a.genome.payload.index];
      // Pulse in time with the ability's own cadence so the visual reads as
      // the moment damage lands.
      final phase = (a.visualPhase / a.genome.cooldown) % 1.0;
      final alpha = (0.30 + 0.22 * math.sin(phase * math.pi * 2)).clamp(0.0, 1.0);
      final tier = a.genome.visualTier;
      // Width grows only gently with tier: an aura is already the largest
      // thing on screen, and a thick stroke plus its blur halo swallows the
      // swarm the player needs to read.
      _rings.add(_Ring(world.px, world.py, a.genome.range,
          pf.bright, alpha * 0.85, 1.8 + tier * 0.25));
      // A faint filled disc makes the damaging area unambiguous.
      _rings.add(_Ring(world.px, world.py, a.genome.range,
          pf.mid, alpha * 0.13, 0));

      // Deeper lineages get an inner band and orbiting motes, so an evolved
      // aura is obviously more than a bigger circle.
      if (tier >= 2) {
        _rings.add(_Ring(world.px, world.py, a.genome.range * 0.62,
            pf.bright, alpha * 0.35, 1.2));
      }
      if (tier >= 3) {
        final spark = pf.spark;
        final n = math.min(6, 3 + tier);
        for (var i = 0; i < n; i++) {
          final ang = a.visualPhase * 1.1 + i * (math.pi * 2 / n);
          _additive.add(spark, world.px + math.cos(ang) * a.genome.range,
              world.py + math.sin(ang) * a.genome.range,
              scale: 0.8 + tier * 0.06);
        }
      }
    }
  }

  void _drawPickups(World world) {
    final xpSmall = _xpSmallFrame;
    final xpLarge = _xpLargeFrame;
    final heal = _healFrame;
    for (final p in world.pickups) {
      if (!p.alive) continue;
      if (p.isHealth) {
        _additive.add(heal, p.x, p.y);
      } else {
        _additive.add(p.value >= 5 ? xpLarge : xpSmall, p.x, p.y);
      }
    }
  }

  void _drawShots(World world, {required bool under}) {
    for (final s in world.shots) {
      if (!s.alive) continue;
      // Mines and waves sit beneath the swarm; projectiles ride on top.
      final isUnder = s.kind == ShotKind.mine || s.kind == ShotKind.wave;
      if (isUnder != under) continue;

      final pf = _payloadFrames[s.payload.index];
      final genome = world.abilityForSlot(s.slot)?.genome;
      final tier = genome?.visualTier ?? 0;
      // Hybrids decorate in their second payload's colour, so a Frost+Burn
      // projectile reads as two-toned rather than tinted.
      final accent = genome?.subPayload != null
          ? _payloadFrames[genome!.subPayload!.index]
          : pf;
      // Projectiles get visibly heavier as the lineage deepens.
      final grow = 1.0 + tier * 0.07;

      switch (s.kind) {
        case ShotKind.bolt:
          _additive.add(pf.bolt, s.x, s.y, rotation: s.spin, scale: grow);
          _decorate(s, tier, pf, accent, world.time);
          break;
        case ShotKind.seeker:
          _additive.add(pf.orb, s.x, s.y, scale: 0.9 * grow);
          _decorate(s, tier, pf, accent, world.time);
          break;
        case ShotKind.orbit:
          _additive.add(pf.orb, s.x, s.y, rotation: s.spin, scale: 1.1 * grow);
          _decorate(s, tier, pf, accent, world.time);
          break;
        case ShotKind.mine:
          // Breathes, so a dropped mine stays legible against the backdrop.
          // Drawn as a disc plus a small sprite core rather than one hugely
          // scaled sprite — a mine's radius grows with Reach, and blowing a
          // 13px sprite up to cover it looks like a broken texture.
          final pulse = 0.9 + 0.12 * math.sin(s.life * 7);
          _rings.add(_Ring(s.x, s.y, s.radius * pulse, pf.bright, 0.55, 2.0 + tier * 0.4));
          _rings.add(_Ring(s.x, s.y, s.radius * pulse, pf.bright, 0.10, 0));
          _additive.add(pf.orb, s.x, s.y, scale: 1.15 * grow);
          _decorate(s, tier, pf, accent, world.time);
          break;
        case ShotKind.wave:
          if (s.waveRadius <= 0) break;
          final fade = (1.0 - s.waveRadius / s.waveMax).clamp(0.0, 1.0);
          _rings.add(_Ring(s.x, s.y, s.waveRadius, pf.bright, fade, 3.0 + tier * 0.8));
          // A trailing second edge in the accent colour turns a plain ring
          // into a shockwave with depth.
          if (tier >= 2) {
            _rings.add(_Ring(s.x, s.y, s.waveRadius * 0.86, accent.bright, fade * 0.5, 1.5));
          }
          break;
      }
    }
  }

  /// Layers decoration onto a projectile according to its lineage depth.
  ///
  /// Each tier adds a distinct element rather than scaling the last one, so
  /// the progression reads as an ability gaining structure — motes, then a
  /// halo, then a counter-rotating pair, then a hot core. All of it goes
  /// through the same sprite batch, so an elaborate build costs no extra draw
  /// calls.
  void _decorate(Shot s, int tier, _PayloadFrames pf, _PayloadFrames accent, double time) {
    if (tier <= 0) return;

    final spark = accent.spark;

    // Tier 1-2: motes orbiting the projectile.
    final motes = tier >= 2 ? 3 : 2;
    final orbitR = 6.0 + tier * 0.7;
    final spin = time * (2.4 + tier * 0.5) + s.spin;
    for (var i = 0; i < motes; i++) {
      final a = spin + i * (math.pi * 2 / motes);
      _additive.add(spark, s.x + math.cos(a) * orbitR, s.y + math.sin(a) * orbitR,
          scale: 0.75 + tier * 0.05);
    }

    // Tier 3: a halo. Uses the small ring frame at low scale, which stays
    // crisp — unlike the large expanding rings, which have to be stroked.
    if (tier >= 3) {
      _additive.add(accent.ring, s.x, s.y,
          scale: (orbitR + 3) / 15.0, rotation: spin * 0.4, color: 0xB0FFFFFF);
    }

    // Tier 4: a second set of motes running the other way.
    if (tier >= 4) {
      for (var i = 0; i < 4; i++) {
        final a = -spin * 0.7 + i * (math.pi / 2);
        final r = orbitR + 4.5;
        _additive.add(pf.spark, s.x + math.cos(a) * r, s.y + math.sin(a) * r,
            scale: 0.6, color: 0xCCFFFFFF);
      }
    }

    // Tier 5: a pulsing core flare.
    if (tier >= 5) {
      final pulse = 0.9 + 0.25 * math.sin(time * 7 + s.spin);
      _additive.add(pf.burst, s.x, s.y, scale: 0.85 * pulse, color: 0x88FFFFFF);
    }
  }

  void _drawEnemies(World world) {
    for (final e in world.enemies) {
      if (!e.alive) continue;
      final variants = _enemyFrames[e.def.archetype]!;
      final frame = variants[e.variant % variants.length];

      // Damage flash: tint toward white briefly on hit.
      var color = 0xFFFFFFFF;
      if (e.flash > 0) {
        final t = (e.flash / 0.12).clamp(0.0, 1.0);
        final v = (255 - 90 * t).round().clamp(0, 255);
        // Modulate can only darken, so the flash reads as a bright rim by
        // pairing a slightly darkened body with an additive overlay below.
        color = 0xFF000000 | (v << 16) | (v << 8) | 0xFF;
      }

      // Frozen enemies read blue; stunned ones jitter.
      var ox = 0.0, oy = 0.0;
      if (e.stunTime > 0) {
        ox = math.sin(e.stunTime * 60) * 1.2;
      }
      if (e.slowTime > 0) {
        color = 0xFF9BD8FF;
      }

      _opaque.add(frame, e.x + ox, e.y + oy, color: color);

      if (e.flash > 0) {
        final t = (e.flash / 0.12).clamp(0.0, 1.0);
        _additive.add(frame, e.x + ox, e.y + oy,
            color: ((160 * t).round() << 24) | 0x00FFFFFF);
      }
    }
  }

  void _drawPlayer(World world) {
    final frame = _hostFrame;
    // Blink through invulnerability frames after taking a hit.
    if (world.invulnerable > 0 && (world.invulnerable * 18).floor() % 2 == 0) {
      _opaque.add(frame, world.px, world.py, color: 0xFF808080);
    } else {
      _opaque.add(frame, world.px, world.py);
    }
  }

  void _drawParticles(World world) {
    for (final p in world.particles) {
      if (!p.alive) continue;
      final fade = (p.life / p.maxLife).clamp(0.0, 1.0);

      // Detonation rings expand far past their sprite's native size, so they
      // are stroked rather than blitted.
      if (p.frame.startsWith('ring_')) {
        final key = p.frame.substring(5);
        // Ease outward as it fades, which reads as a shockwave rather than a
        // circle that simply blinks out.
        final radius = p.scale * 15.0 * (0.55 + 0.45 * (1 - fade));
        _rings.add(_Ring(p.x, p.y, radius, atlas.payloadColor(key, 3), fade, 2.5));
        continue;
      }

      final alpha = (255 * fade).round();
      _additive.add(atlas.frame(p.frame), p.x, p.y,
          scale: p.scale, rotation: p.spin, color: (alpha << 24) | (p.color & 0x00FFFFFF));
    }
  }

  /// Strokes the collected rings. A blurred pass under a crisp one gives the
  /// bloom without needing a shader.
  void _flushRings(ui.Canvas canvas) {
    if (_rings.isEmpty) return;
    final paint = ui.Paint()..blendMode = ui.BlendMode.plus;

    for (final r in _rings) {
      if (r.alpha <= 0.01 || r.radius <= 0.5) continue;
      final centre = ui.Offset(r.x, r.y);

      if (r.width <= 0) {
        // Filled disc, used for aura interiors.
        canvas.drawCircle(
            centre,
            r.radius,
            paint
              ..style = ui.PaintingStyle.fill
              ..color = r.color.withValues(alpha: r.alpha));
        continue;
      }

      // Two stacked strokes instead of a real blur.
      //
      // MaskFilter.blur was by far the most expensive operation in this
      // renderer — a genuine gaussian per ring, per frame, and rings are
      // everywhere once auras and waves are in play. Additively compositing a
      // wide translucent stroke under a narrow bright one reads almost
      // identically against a dark background and costs two ordinary circles.
      canvas.drawCircle(
          centre,
          r.radius,
          paint
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = r.width * 3.0
            ..color = r.color.withValues(alpha: r.alpha * 0.22));

      canvas.drawCircle(
          centre,
          r.radius,
          paint
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = r.width
            ..color = r.color.withValues(alpha: r.alpha));
    }
  }

  /// Chain jumps and beam sweeps, drawn as fading lines.
  ///
  /// Instant vectors have no entity to render, so without this they are
  /// invisible at anything but the closest zoom.
  void _drawArcs(ui.Canvas canvas, World world) {
    final paint = ui.Paint()
      ..blendMode = ui.BlendMode.plus
      ..style = ui.PaintingStyle.stroke
      ..strokeCap = ui.StrokeCap.round;

    for (final a in world.arcs) {
      if (!a.alive) continue;
      final fade = (a.life / a.maxLife).clamp(0.0, 1.0);
      final colour = _payloadFrames[a.payload.index].bright;
      final p1 = ui.Offset(a.x1, a.y1);
      final p2 = ui.Offset(a.x2, a.y2);

      // Wide soft pass under a narrow bright one, the same trick the rings
      // use, so the bolt glows without a blur.
      canvas.drawLine(p1, p2,
          paint
            ..strokeWidth = a.width * 3
            ..color = colour.withValues(alpha: fade * 0.22));
      canvas.drawLine(p1, p2,
          paint
            ..strokeWidth = a.width
            ..color = colour.withValues(alpha: fade));
    }
  }

  /// Tethers are a handful of lines at most, so a direct draw is cheaper than
  /// routing them through the atlas.
  void _drawTethers(ui.Canvas canvas, World world) {
    for (final a in world.abilities) {
      if (a.genome.vector != Vector.tether) continue;
      final t = a.tetherTarget;
      if (t == null || !t.alive) continue;

      final tier = a.genome.visualTier;
      final color = _payloadFrames[a.genome.payload.index].bright;
      final paint = ui.Paint()
        ..color = color.withValues(alpha: 0.85)
        ..strokeWidth = 2.0 + tier * 0.6
        ..blendMode = ui.BlendMode.plus
        ..strokeCap = ui.StrokeCap.round;
      canvas.drawLine(ui.Offset(world.px, world.py), ui.Offset(t.x, t.y), paint);

      // An evolved tether braids: a second strand bows away from the first,
      // so the link reads as thicker rope rather than a heavier line.
      if (tier >= 2) {
        final dx = t.x - world.px, dy = t.y - world.py;
        final len = math.sqrt(dx * dx + dy * dy);
        if (len > 1) {
          final nx = -dy / len, ny = dx / len;
          final bow = 4.0 + tier * 1.5;
          final wobble = math.sin(a.visualPhase * 6) * bow;
          final path = ui.Path()
            ..moveTo(world.px, world.py)
            ..quadraticBezierTo(
                world.px + dx * 0.5 + nx * wobble,
                world.py + dy * 0.5 + ny * wobble,
                t.x, t.y);
          canvas.drawPath(
              path,
              ui.Paint()
                ..style = ui.PaintingStyle.stroke
                ..color = _payloadFrames[
                        (a.genome.subPayload ?? a.genome.payload).index]
                    .bright
                    .withValues(alpha: 0.6)
                ..strokeWidth = 1.5
                ..blendMode = ui.BlendMode.plus);
        }
      }
    }
  }

  /// Only for enemies substantial enough that their health is worth reading.
  ///
  /// Gated on archetype rather than an absolute health threshold. Enemy health
  /// scales with run time, so a fixed cutoff eventually matches *every* enemy
  /// on screen and silently adds a hundred draw calls a frame late in a run.
  void _drawHealthBars(ui.Canvas canvas, World world) {
    final bg = ui.Paint()..color = const ui.Color(0xCC101018);
    for (final e in world.enemies) {
      if (!e.alive || !e.def.showsHealthBar) continue;
      final frac = (e.hp / e.maxHp).clamp(0.0, 1.0);
      final w = e.radius * 2.2;
      final y = e.y - e.radius - 6;
      final rect = ui.Rect.fromLTWH(e.x - w / 2, y, w, 2.4);
      canvas.drawRect(rect, bg);
      canvas.drawRect(
        ui.Rect.fromLTWH(e.x - w / 2, y, w * frac, 2.4),
        ui.Paint()..color = const ui.Color(0xFFF6605A),
      );
    }
  }

  void _drawVignette(ui.Canvas canvas, ui.Size size) {
    if (_vignette == null || _vignetteSize != size) {
      _vignetteSize = size;
      _vignette = ui.Gradient.radial(
        ui.Offset(size.width / 2, size.height / 2),
        math.max(size.width, size.height) * 0.72,
        const [ui.Color(0x00000000), ui.Color(0x00000000), ui.Color(0x99000000)],
        const [0.0, 0.55, 1.0],
      );
    }
    canvas.drawRect(ui.Offset.zero & size, ui.Paint()..shader = _vignette);
  }

  void _drawJoystick(ui.Canvas canvas, TouchController touch) {
    if (!touch.active) return;

    final base = ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const ui.Color(0x40C8FFFA);
    final knob = ui.Paint()..color = const ui.Color(0x66C8FFFA);

    canvas.drawCircle(touch.origin, TouchController.radius, base);
    canvas.drawCircle(touch.knob, 16, knob);
  }
}

/// Pre-resolved atlas rects and colours for one damage type.
class _PayloadFrames {
  final ui.Rect spark, orb, burst, bolt, shard, ring;
  final ui.Color bright, mid;

  const _PayloadFrames._(this.spark, this.orb, this.burst, this.bolt, this.shard,
      this.ring, this.bright, this.mid);

  factory _PayloadFrames.of(SpriteAtlas atlas, String key) => _PayloadFrames._(
        atlas.frame('spark_$key'),
        atlas.frame('orb_$key'),
        atlas.frame('burst_$key'),
        atlas.frame('bolt_$key'),
        atlas.frame('shard_$key'),
        atlas.frame('ring_$key'),
        atlas.payloadColor(key, 3),
        atlas.payloadColor(key, 2),
      );
}

/// A circle queued for stroking after the sprite batches.
class _Ring {
  final double x, y, radius, alpha, width;
  final ui.Color color;

  /// A [width] of zero means a filled disc rather than a stroked ring.
  const _Ring(this.x, this.y, this.radius, this.color, this.alpha, this.width);
}

/// Keyboard steering for desktop and web.
///
/// Kept separate from the joystick rather than folded into it: the two are
/// live at the same time on a laptop with a touchscreen, and whichever the
/// player last used should win without either resetting the other.
class KeyboardController {
  static final _left = <LogicalKeyboardKey>{
    LogicalKeyboardKey.keyA,
    LogicalKeyboardKey.arrowLeft,
  };
  static final _right = <LogicalKeyboardKey>{
    LogicalKeyboardKey.keyD,
    LogicalKeyboardKey.arrowRight,
  };
  static final _up = <LogicalKeyboardKey>{
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.arrowUp,
  };
  static final _down = <LogicalKeyboardKey>{
    LogicalKeyboardKey.keyS,
    LogicalKeyboardKey.arrowDown,
  };

  final Set<LogicalKeyboardKey> _held = {};

  double dx = 0, dy = 0;

  /// Raw count of key events delivered to the game, incremented before any
  /// filtering. Diagnostic only: zero here means the browser or engine is not
  /// delivering keys at all, which is a completely different problem from the
  /// game ignoring them.
  int eventsSeen = 0;

  /// True while any direction is held, so the game knows to prefer the
  /// keyboard over a stale joystick reading.
  bool get active => dx != 0 || dy != 0;

  /// Feeds a raw key event. Returns true if it was a movement key, so the
  /// caller can let anything else through to the rest of the app.
  bool handle(KeyEvent event) {
    final key = event.logicalKey;
    final isMovement = _left.contains(key) ||
        _right.contains(key) ||
        _up.contains(key) ||
        _down.contains(key);
    if (!isMovement) return false;

    if (event is KeyDownEvent) {
      _held.add(key);
    } else if (event is KeyUpEvent) {
      _held.remove(key);
    }
    // Repeat events are ignored: the key is already held.
    _recompute();
    return true;
  }

  /// Drops all held keys. Called when focus is lost, or a key-up would never
  /// arrive and the player would run in one direction forever.
  void clear() {
    _held.clear();
    _recompute();
  }

  void _recompute() {
    var x = 0.0, y = 0.0;
    if (_held.any(_left.contains)) x -= 1;
    if (_held.any(_right.contains)) x += 1;
    if (_held.any(_up.contains)) y -= 1;
    if (_held.any(_down.contains)) y += 1;

    // Normalise, or diagonal movement would be 41% faster than cardinal.
    if (x != 0 && y != 0) {
      const inv = 0.7071067811865476;
      x *= inv;
      y *= inv;
    }
    dx = x;
    dy = y;
  }
}

/// Floating one-thumb joystick.
///
/// The stick materialises wherever the thumb lands rather than living in a
/// fixed corner, which is what makes a twin-stick-less game playable one
/// handed on a phone.
class TouchController {
  static const double radius = 56;
  static const double deadZone = 5;

  /// How far the camera may be pulled in or pushed out.
  static const double minZoom = 0.55;
  static const double maxZoom = 1.9;

  bool active = false;
  int? pointerId;
  ui.Offset origin = ui.Offset.zero;
  ui.Offset knob = ui.Offset.zero;

  double dx = 0, dy = 0;

  /// Camera zoom multiplier, driven by a two-finger pinch. Above 1 shows less
  /// of the world; below 1 shows more.
  double zoom = 1.0;

  /// Live pointers, so a second finger can start a pinch.
  final Map<int, ui.Offset> _pointers = {};

  double _pinchStartDistance = 0;
  double _pinchStartZoom = 1.0;

  bool get pinching => _pointers.length >= 2;

  void down(int pointer, ui.Offset position) {
    _pointers[pointer] = position;

    if (_pointers.length >= 2) {
      _beginPinch();
      return;
    }
    if (active) return;
    active = true;
    pointerId = pointer;
    origin = position;
    knob = position;
    dx = dy = 0;
  }

  void move(int pointer, ui.Offset position) {
    if (_pointers.containsKey(pointer)) _pointers[pointer] = position;

    if (pinching) {
      final d = _currentPinchDistance();
      if (_pinchStartDistance > 1 && d > 1) {
        zoom = (_pinchStartZoom * (d / _pinchStartDistance)).clamp(minZoom, maxZoom);
      }
      return;
    }

    if (!active || pointer != pointerId) return;
    var delta = position - origin;
    final dist = delta.distance;

    // Once the thumb travels past the ring, drag the ring along with it so the
    // stick never feels like it has run out of room.
    if (dist > radius) {
      origin = position - delta * (radius / dist);
      delta = delta * (radius / dist);
    }
    knob = origin + delta;

    if (dist < deadZone) {
      dx = dy = 0;
    } else {
      final len = delta.distance;
      dx = delta.dx / len;
      dy = delta.dy / len;
    }
  }

  void up(int pointer) {
    _pointers.remove(pointer);

    // Dropping from two fingers to one must not resume steering from the
    // stale joystick origin — the remaining finger has moved a long way during
    // the pinch, which would fling the player across the screen.
    if (_pointers.length == 1) {
      active = false;
      pointerId = null;
      dx = dy = 0;
      return;
    }

    if (pointer != pointerId) return;
    active = false;
    pointerId = null;
    dx = dy = 0;
  }

  /// Adjusts zoom by a relative amount, for mouse-wheel input.
  void nudgeZoom(double delta) {
    zoom = (zoom * (1 + delta)).clamp(minZoom, maxZoom);
  }

  void _beginPinch() {
    _pinchStartDistance = _currentPinchDistance();
    _pinchStartZoom = zoom;
    // Steering stops while pinching, or the player drifts while framing.
    active = false;
    pointerId = null;
    dx = dy = 0;
  }

  double _currentPinchDistance() {
    final points = _pointers.values.toList();
    if (points.length < 2) return 0;
    return (points[0] - points[1]).distance;
  }
}
