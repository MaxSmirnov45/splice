import 'package:flutter/foundation.dart' show kIsWeb;
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
  var pauses = 0;
  var blocked = false;

  setUp(() {
    pauses = 0;
    blocked = false;
    input = GameInput(onPause: () => pauses++, blocked: () => blocked)..install();
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

  testWidgets('P reaches the pause handler', (tester) async {
    await simulateKeyDownEvent(LogicalKeyboardKey.keyP);
    expect(pauses, 1);
  });

  // Escape is the portal's, not the game's: it is what leaves fullscreen, and
  // a game that swallows it traps the player in a fullscreen frame. It stays
  // bound off the web, where nothing else claims it — and this runs on the VM,
  // so that is the branch under test here.
  testWidgets('escape pauses away from the web', (tester) async {
    await simulateKeyDownEvent(LogicalKeyboardKey.escape);
    expect(pauses, 1);
  });

  test('the web never treats escape as a pause key', () {
    // Asserted on the classifier rather than through a simulated press, since
    // a VM test cannot pretend to be a browser.
    const escape = KeyDownEvent(
      logicalKey: LogicalKeyboardKey.escape,
      physicalKey: PhysicalKeyboardKey.escape,
      timeStamp: Duration.zero,
    );
    const p = KeyDownEvent(
      logicalKey: LogicalKeyboardKey.keyP,
      physicalKey: PhysicalKeyboardKey.keyP,
      timeStamp: Duration.zero,
    );
    expect(GameInput.isPauseKey(p), isTrue,
        reason: 'P must pause everywhere, since escape cannot on the web');
    expect(GameInput.isPauseKey(escape), !kIsWeb,
        reason: 'escape may only pause where the platform does not own it');
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

  testWidgets('the pause key still works while a menu is open', (tester) async {
    blocked = true;
    await simulateKeyDownEvent(LogicalKeyboardKey.keyP);
    expect(pauses, 1, reason: 'the pause key must resume, not be swallowed');
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
