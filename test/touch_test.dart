import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/render/renderer.dart';

/// One thumb steers, two fingers zoom. The two must not interfere: a pinch
/// that also steers, or a pinch release that resumes steering from a stale
/// origin, would fling the player across the screen mid-gesture.
void main() {
  test('a single finger steers', () {
    final t = TouchController();
    t.down(1, const Offset(100, 100));
    t.move(1, const Offset(140, 100));
    expect(t.active, isTrue);
    expect(t.dx, greaterThan(0.9));
    expect(t.dy.abs(), lessThan(0.1));
  });

  test('a second finger starts a pinch and stops steering', () {
    final t = TouchController();
    t.down(1, const Offset(100, 100));
    t.move(1, const Offset(150, 100));
    expect(t.dx, greaterThan(0));

    t.down(2, const Offset(300, 100));
    expect(t.pinching, isTrue);
    expect(t.active, isFalse, reason: 'the joystick must let go during a pinch');
    expect(t.dx, 0);
    expect(t.dy, 0);
  });

  test('spreading zooms in, pinching zooms out', () {
    final t = TouchController();
    t.down(1, const Offset(200, 400));
    t.down(2, const Offset(300, 400)); // 100px apart
    final start = t.zoom;

    t.move(2, const Offset(400, 400)); // 200px apart
    expect(t.zoom, greaterThan(start));

    t.move(2, const Offset(250, 400)); // 50px apart
    expect(t.zoom, lessThan(start));
  });

  test('zoom stays within its limits', () {
    final t = TouchController();
    t.down(1, const Offset(200, 400));
    t.down(2, const Offset(210, 400));
    t.move(2, const Offset(3000, 400));
    expect(t.zoom, lessThanOrEqualTo(TouchController.maxZoom));

    final t2 = TouchController();
    t2.down(1, const Offset(200, 400));
    t2.down(2, const Offset(900, 400));
    t2.move(2, const Offset(201, 400));
    expect(t2.zoom, greaterThanOrEqualTo(TouchController.minZoom));
  });

  test('zoom persists after the pinch ends', () {
    final t = TouchController();
    t.down(1, const Offset(200, 400));
    t.down(2, const Offset(300, 400));
    t.move(2, const Offset(450, 400));
    final zoomed = t.zoom;
    t.up(2);
    t.up(1);
    expect(t.zoom, zoomed, reason: 'the camera should stay where it was set');
  });

  test('lifting one finger does not resume steering from a stale origin', () {
    final t = TouchController();
    t.down(1, const Offset(200, 400));
    t.down(2, const Offset(300, 400));
    // The remaining finger travels a long way during the pinch.
    t.move(1, const Offset(50, 700));
    t.up(2);

    // Steering must not restart from the original touch point, which would
    // read as a huge stick deflection the player never made.
    expect(t.active, isFalse);
    expect(t.dx, 0);
    expect(t.dy, 0);
  });

  test('a second pinch continues from the current zoom', () {
    final t = TouchController();
    // Modest gestures, so neither pinch saturates the zoom ceiling and the
    // compounding is actually observable.
    t.down(1, const Offset(200, 400));
    t.down(2, const Offset(300, 400)); // 100px
    t.move(2, const Offset(325, 400)); // 125px -> 1.25x
    final first = t.zoom;
    expect(first, lessThan(TouchController.maxZoom));
    t.up(2);
    t.up(1);

    t.down(3, const Offset(200, 400));
    t.down(4, const Offset(300, 400));
    t.move(4, const Offset(325, 400));
    expect(t.zoom, greaterThan(first), reason: 'zoom must compound, not reset');
    expect(t.zoom, lessThanOrEqualTo(TouchController.maxZoom));
  });
}
