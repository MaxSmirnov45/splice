import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Color;
import 'package:flutter/services.dart' show rootBundle;

/// The texture atlas built by `tools/atlas.py`, plus the palette metadata that
/// travels with it so UI and particles can tint to match the sprites.
class SpriteAtlas {
  final ui.Image image;
  final Map<String, ui.Rect> frames;
  final Map<String, String> payloadPalette;
  final Map<String, String> speciesPalette;
  final Map<String, List<Color>> palettes;
  final int variants;

  SpriteAtlas._({
    required this.image,
    required this.frames,
    required this.payloadPalette,
    required this.speciesPalette,
    required this.palettes,
    required this.variants,
  });

  static Future<SpriteAtlas> load() async {
    final manifest =
        jsonDecode(await rootBundle.loadString('assets/atlas.json')) as Map<String, dynamic>;

    final bytes = await rootBundle.load('assets/atlas.png');
    final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
    final image = (await codec.getNextFrame()).image;

    final frames = <String, ui.Rect>{};
    (manifest['frames'] as Map<String, dynamic>).forEach((name, v) {
      final r = (v as List).cast<num>();
      frames[name] = ui.Rect.fromLTWH(
          r[0].toDouble(), r[1].toDouble(), r[2].toDouble(), r[3].toDouble());
    });

    final palettes = <String, List<Color>>{};
    (manifest['palettes'] as Map<String, dynamic>).forEach((name, v) {
      palettes[name] = (v as List)
          .cast<String>()
          .map((h) => Color(0xFF000000 | int.parse(h.substring(1), radix: 16)))
          .toList();
    });

    return SpriteAtlas._(
      image: image,
      frames: frames,
      payloadPalette: (manifest['payloadPalette'] as Map<String, dynamic>).cast<String, String>(),
      speciesPalette: (manifest['speciesPalette'] as Map<String, dynamic>).cast<String, String>(),
      palettes: palettes,
      variants: (manifest['variants'] as num).toInt(),
    );
  }

  ui.Rect frame(String name) {
    final r = frames[name];
    if (r == null) throw StateError('atlas has no frame "$name"');
    return r;
  }

  /// Ramp stop for a damage type. Index 4 is the hot core, 3 the rim.
  Color payloadColor(String payload, [int stop = 3]) {
    final ramp = palettes[payloadPalette[payload] ?? 'bone']!;
    return ramp[stop.clamp(0, ramp.length - 1)];
  }
}

/// Accumulates sprites into flat buffers and submits them as a single
/// `drawRawAtlas` call.
///
/// Every entity in the game funnels through here, so the entire scene costs one
/// draw call per blend mode rather than one per sprite. Buffers are reused
/// between frames; nothing allocates in steady state.
class SpriteBatch {
  static const int _initialCapacity = 512;

  Float32List _xform = Float32List(_initialCapacity * 4);
  Float32List _rects = Float32List(_initialCapacity * 4);
  Int32List _colors = Int32List(_initialCapacity);
  int _count = 0;

  int get count => _count;

  void clear() => _count = 0;

  void _grow() {
    final cap = _colors.length * 2;
    _xform = Float32List(cap * 4)..setRange(0, _count * 4, _xform);
    _rects = Float32List(cap * 4)..setRange(0, _count * 4, _rects);
    _colors = Int32List(cap)..setRange(0, _count, _colors);
  }

  /// Queues one sprite centred on ([cx], [cy]) in world space.
  ///
  /// [color] is multiplied into the sprite (modulate), so its alpha channel
  /// doubles as a fade and its RGB as a tint.
  void add(
    ui.Rect src,
    double cx,
    double cy, {
    double scale = 1.0,
    double rotation = 0.0,
    int color = 0xFFFFFFFF,
  }) {
    if (_count == _colors.length) _grow();

    final double scos, ssin;
    if (rotation == 0.0) {
      scos = scale;
      ssin = 0.0;
    } else {
      scos = _cos(rotation) * scale;
      ssin = _sin(rotation) * scale;
    }

    // Anchor at the frame's centre so entities are positioned by their middle.
    final ax = src.width * 0.5;
    final ay = src.height * 0.5;

    final i = _count * 4;
    _xform[i] = scos;
    _xform[i + 1] = ssin;
    _xform[i + 2] = cx - scos * ax + ssin * ay;
    _xform[i + 3] = cy - ssin * ax - scos * ay;

    _rects[i] = src.left;
    _rects[i + 1] = src.top;
    _rects[i + 2] = src.right;
    _rects[i + 3] = src.bottom;

    _colors[_count] = color;
    _count++;
  }

  void render(ui.Canvas canvas, ui.Image image, ui.Paint paint,
      {ui.BlendMode tint = ui.BlendMode.modulate}) {
    if (_count == 0) return;
    canvas.drawRawAtlas(
      image,
      Float32List.sublistView(_xform, 0, _count * 4),
      Float32List.sublistView(_rects, 0, _count * 4),
      Int32List.sublistView(_colors, 0, _count),
      tint,
      null,
      paint,
    );
  }

  // A sine lookup keeps the per-sprite cost low when thousands of rotated
  // particles are queued each frame. Sprite rotation does not need more
  // precision than this table provides.
  static const int _tableSize = 2048;
  static const double _tau = 6.283185307179586;
  static const double _halfPi = 1.5707963267948966;

  static final Float32List _sinTable = () {
    final t = Float32List(_tableSize);
    for (var i = 0; i < _tableSize; i++) {
      t[i] = math.sin(i * _tau / _tableSize);
    }
    return t;
  }();

  static double _sin(double radians) {
    var i = (radians * (_tableSize / _tau)).toInt() % _tableSize;
    if (i < 0) i += _tableSize;
    return _sinTable[i];
  }

  static double _cos(double radians) => _sin(radians + _halfPi);
}
