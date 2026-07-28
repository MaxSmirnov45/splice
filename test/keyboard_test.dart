import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/render/renderer.dart';

/// Steering is matched by physical position, so these events carry the
/// position that matters and a deliberately unrelated logical key.
///
/// The mismatch is the point: it is exactly what a French AZERTY keyboard
/// produces. Pressing the key where W sits reports the logical key Z, and the
/// game must move up regardless.
KeyEvent _down(PhysicalKeyboardKey k) => KeyDownEvent(
      logicalKey: LogicalKeyboardKey.f24,
      physicalKey: k,
      timeStamp: Duration.zero,
    );
KeyEvent _up(PhysicalKeyboardKey k) => KeyUpEvent(
      logicalKey: LogicalKeyboardKey.f24,
      physicalKey: k,
      timeStamp: Duration.zero,
    );

/// WASD and arrow steering for laptop and web play.
void main() {
  test('WASD moves in the right directions', () {
    final k = KeyboardController();
    k.handle(_down(PhysicalKeyboardKey.keyD));
    expect(k.dx, 1);
    expect(k.dy, 0);

    k.handle(_up(PhysicalKeyboardKey.keyD));
    k.handle(_down(PhysicalKeyboardKey.keyW));
    expect(k.dy, -1, reason: 'W is up, and screen Y grows downward');
  });

  test('arrow keys work as well as WASD', () {
    final k = KeyboardController();
    k.handle(_down(PhysicalKeyboardKey.arrowLeft));
    expect(k.dx, -1);
    // Release before testing the next axis, or this is a diagonal and both
    // components are correctly scaled to 0.707.
    k.handle(_up(PhysicalKeyboardKey.arrowLeft));
    k.handle(_down(PhysicalKeyboardKey.arrowDown));
    expect(k.dy, 1);
    expect(k.dx, 0);
  });

  test('diagonals are normalised', () {
    final k = KeyboardController();
    k.handle(_down(PhysicalKeyboardKey.keyW));
    k.handle(_down(PhysicalKeyboardKey.keyD));
    final speed = k.dx * k.dx + k.dy * k.dy;
    // Without normalising, diagonal movement would be 41% faster.
    expect(speed, closeTo(1.0, 0.001));
  });

  test('opposite keys cancel', () {
    final k = KeyboardController();
    k.handle(_down(PhysicalKeyboardKey.keyA));
    k.handle(_down(PhysicalKeyboardKey.keyD));
    expect(k.dx, 0);
    expect(k.active, isFalse);
  });

  test('releasing stops movement', () {
    final k = KeyboardController();
    k.handle(_down(PhysicalKeyboardKey.keyD));
    expect(k.active, isTrue);
    k.handle(_up(PhysicalKeyboardKey.keyD));
    expect(k.active, isFalse);
    expect(k.dx, 0);
  });

  test('clear drops stuck keys', () {
    final k = KeyboardController();
    k.handle(_down(PhysicalKeyboardKey.keyW));
    // A menu steals focus and the key-up never arrives; without clear() the
    // player would run upward forever on return.
    k.clear();
    expect(k.active, isFalse);
  });

  test('non-movement keys are passed through', () {
    final k = KeyboardController();
    expect(k.handle(_down(PhysicalKeyboardKey.keyQ)), isFalse);
    expect(k.handle(_down(PhysicalKeyboardKey.keyD)), isTrue);
  });

  test('an AZERTY keyboard steers with the same four keys', () {
    // On AZERTY the key in W's position reports the logical key Z, and the one
    // in A's position reports Q. A logical binding leaves those players with
    // no keyboard movement at all unless they rebind their operating system.
    final k = KeyboardController();
    k.handle(KeyDownEvent(
      logicalKey: LogicalKeyboardKey.keyZ,
      physicalKey: PhysicalKeyboardKey.keyW,
      timeStamp: Duration.zero,
    ));
    expect(k.dy, -1, reason: 'the key under the same finger must move up');

    k.handle(KeyDownEvent(
      logicalKey: LogicalKeyboardKey.keyQ,
      physicalKey: PhysicalKeyboardKey.keyA,
      timeStamp: Duration.zero,
    ));
    expect(k.dx, lessThan(0), reason: 'and the one beside it must move left');
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
