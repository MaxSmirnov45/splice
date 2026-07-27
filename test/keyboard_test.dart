import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/render/renderer.dart';

KeyEvent _down(LogicalKeyboardKey k) =>
    KeyDownEvent(logicalKey: k, physicalKey: PhysicalKeyboardKey.keyA, timeStamp: Duration.zero);
KeyEvent _up(LogicalKeyboardKey k) =>
    KeyUpEvent(logicalKey: k, physicalKey: PhysicalKeyboardKey.keyA, timeStamp: Duration.zero);

/// WASD and arrow steering for laptop and web play.
void main() {
  test('WASD moves in the right directions', () {
    final k = KeyboardController();
    k.handle(_down(LogicalKeyboardKey.keyD));
    expect(k.dx, 1);
    expect(k.dy, 0);

    k.handle(_up(LogicalKeyboardKey.keyD));
    k.handle(_down(LogicalKeyboardKey.keyW));
    expect(k.dy, -1, reason: 'W is up, and screen Y grows downward');
  });

  test('arrow keys work as well as WASD', () {
    final k = KeyboardController();
    k.handle(_down(LogicalKeyboardKey.arrowLeft));
    expect(k.dx, -1);
    // Release before testing the next axis, or this is a diagonal and both
    // components are correctly scaled to 0.707.
    k.handle(_up(LogicalKeyboardKey.arrowLeft));
    k.handle(_down(LogicalKeyboardKey.arrowDown));
    expect(k.dy, 1);
    expect(k.dx, 0);
  });

  test('diagonals are normalised', () {
    final k = KeyboardController();
    k.handle(_down(LogicalKeyboardKey.keyW));
    k.handle(_down(LogicalKeyboardKey.keyD));
    final speed = k.dx * k.dx + k.dy * k.dy;
    // Without normalising, diagonal movement would be 41% faster.
    expect(speed, closeTo(1.0, 0.001));
  });

  test('opposite keys cancel', () {
    final k = KeyboardController();
    k.handle(_down(LogicalKeyboardKey.keyA));
    k.handle(_down(LogicalKeyboardKey.keyD));
    expect(k.dx, 0);
    expect(k.active, isFalse);
  });

  test('releasing stops movement', () {
    final k = KeyboardController();
    k.handle(_down(LogicalKeyboardKey.keyD));
    expect(k.active, isTrue);
    k.handle(_up(LogicalKeyboardKey.keyD));
    expect(k.active, isFalse);
    expect(k.dx, 0);
  });

  test('clear drops stuck keys', () {
    final k = KeyboardController();
    k.handle(_down(LogicalKeyboardKey.keyW));
    // A menu steals focus and the key-up never arrives; without clear() the
    // player would run upward forever on return.
    k.clear();
    expect(k.active, isFalse);
  });

  test('non-movement keys are passed through', () {
    final k = KeyboardController();
    expect(k.handle(_down(LogicalKeyboardKey.keyQ)), isFalse);
    expect(k.handle(_down(LogicalKeyboardKey.keyD)), isTrue);
  });

  test('mouse wheel zoom is clamped', () {
    final t = TouchController();
    for (var i = 0; i < 200; i++) {
      t.nudgeZoom(0.2);
    }
    expect(t.zoom, lessThanOrEqualTo(TouchController.maxZoom));
    for (var i = 0; i < 400; i++) {
      t.nudgeZoom(-0.2);
    }
    expect(t.zoom, greaterThanOrEqualTo(TouchController.minZoom));
  });
}
