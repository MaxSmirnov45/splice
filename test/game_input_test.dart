import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/game/game_input.dart';

/// Verifies keys actually *reach* the game, not merely that the controller
/// computes the right vector once handed an event.
///
/// The original implementation routed keys through a Focus widget, whose
/// onKeyEvent only fires while that node holds focus — and the game surface
/// competes for focus with the engine's own widget, so WASD silently did
/// nothing. Unit tests on the controller passed the whole time, because they
/// bypassed the delivery path entirely. These do not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameInput input;
  var escapes = 0;
  var blocked = false;

  setUp(() {
    escapes = 0;
    blocked = false;
    input = GameInput(onEscape: () => escapes++, blocked: () => blocked)..install();
  });

  tearDown(() => input.dispose());

  testWidgets('a real key press reaches the controller', (tester) async {
    await simulateKeyDownEvent(LogicalKeyboardKey.keyD);
    expect(input.keys.dx, 1, reason: 'D did not reach the game');
    await simulateKeyUpEvent(LogicalKeyboardKey.keyD);
    expect(input.keys.active, isFalse);
  });

  testWidgets('all four directions arrive', (tester) async {
    for (final entry in {
      LogicalKeyboardKey.keyW: [0.0, -1.0],
      LogicalKeyboardKey.keyS: [0.0, 1.0],
      LogicalKeyboardKey.keyA: [-1.0, 0.0],
      LogicalKeyboardKey.keyD: [1.0, 0.0],
    }.entries) {
      await simulateKeyDownEvent(entry.key);
      expect(input.keys.dx, entry.value[0], reason: '${entry.key} dx');
      expect(input.keys.dy, entry.value[1], reason: '${entry.key} dy');
      await simulateKeyUpEvent(entry.key);
    }
  });

  testWidgets('escape reaches the pause handler', (tester) async {
    await simulateKeyDownEvent(LogicalKeyboardKey.escape);
    expect(escapes, 1);
  });

  testWidgets('a menu blocks steering and clears held keys', (tester) async {
    await simulateKeyDownEvent(LogicalKeyboardKey.keyD);
    expect(input.keys.active, isTrue);

    blocked = true;
    await simulateKeyDownEvent(LogicalKeyboardKey.keyW);
    // Otherwise a key-up landing on the menu leaves the player running.
    expect(input.keys.active, isFalse);
    await simulateKeyUpEvent(LogicalKeyboardKey.keyD);
    await simulateKeyUpEvent(LogicalKeyboardKey.keyW);
  });

  testWidgets('escape still works while a menu is open', (tester) async {
    blocked = true;
    await simulateKeyDownEvent(LogicalKeyboardKey.escape);
    expect(escapes, 1, reason: 'escape must resume, not be swallowed');
  });

  testWidgets('unrelated keys are not consumed', (tester) async {
    // Returning true would swallow keys other parts of the app may want.
    expect(input.handleKey(const KeyDownEvent(
      logicalKey: LogicalKeyboardKey.keyQ,
      physicalKey: PhysicalKeyboardKey.keyQ,
      timeStamp: Duration.zero,
    )), isFalse);
  });

  testWidgets('dispose unregisters the handler', (tester) async {
    input.dispose();
    await simulateKeyDownEvent(LogicalKeyboardKey.keyD);
    expect(input.keys.active, isFalse,
        reason: 'a disposed screen must stop receiving keys');
    await simulateKeyUpEvent(LogicalKeyboardKey.keyD);
    input.install(); // so tearDown's dispose is balanced
  });
}
