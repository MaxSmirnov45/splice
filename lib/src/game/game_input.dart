import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../render/renderer.dart';

/// Routes hardware key events into the game.
///
/// Registers directly with [HardwareKeyboard] rather than relying on a [Focus]
/// widget. A focus-based handler only fires while its node actually holds
/// focus, and the game surface competes for focus with the engine's own
/// widget — so keys silently went nowhere. A global handler has no such
/// dependency, which is what a game wants: there are no text fields here to
/// steal typing from.
class GameInput {
  final KeyboardController keys = KeyboardController();

  /// Invoked when a pause key is pressed, for pause/resume.
  final void Function() onPause;

  /// Whether the game is currently accepting steering. While a menu is open,
  /// held keys are dropped so a key-up landing on the menu cannot leave the
  /// player running in one direction forever.
  final bool Function() blocked;

  bool _installed = false;

  GameInput({required this.onPause, required this.blocked});

  void install() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler(handleKey);
  }

  void dispose() {
    if (!_installed) return;
    _installed = false;
    HardwareKeyboard.instance.removeHandler(handleKey);
  }

  /// Whether a key should open or close the pause menu.
  ///
  /// P, always. Escape too — but never on the web, where portals treat it as
  /// theirs: it is what leaves fullscreen, and a game that swallows it traps
  /// the player in a fullscreen frame with no way out. Consuming it is
  /// explicitly against the platform's guidance.
  static bool isPauseKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.physicalKey == PhysicalKeyboardKey.keyP) return true;
    return !kIsWeb && event.logicalKey == LogicalKeyboardKey.escape;
  }

  /// Returns true when the event was consumed by the game.
  bool handleKey(KeyEvent event) {
    keys.eventsSeen++;
    if (isPauseKey(event)) {
      onPause();
      return true;
    }
    if (blocked()) {
      keys.clear();
      return false;
    }
    return keys.handle(event);
  }
}
