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

  /// Invoked when Escape is pressed, for pause/resume.
  final void Function() onEscape;

  /// Whether the game is currently accepting steering. While a menu is open,
  /// held keys are dropped so a key-up landing on the menu cannot leave the
  /// player running in one direction forever.
  final bool Function() blocked;

  bool _installed = false;

  GameInput({required this.onEscape, required this.blocked});

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

  /// Returns true when the event was consumed by the game.
  bool handleKey(KeyEvent event) {
    keys.eventsSeen++;
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      onEscape();
      return true;
    }
    if (blocked()) {
      keys.clear();
      return false;
    }
    return keys.handle(event);
  }
}
