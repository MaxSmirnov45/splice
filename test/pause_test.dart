import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/audio.dart';
import 'package:splice/src/game/splice_game.dart';

/// Pause has to stop the simulation, not merely cover it with a panel.
/// A menu drawn over a still-running world would let enemies close in and
/// kill the player while they read it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uiPaused freezes the world and resuming continues it', () async {
    final game = SpliceGame(seed: 7, enableAudio: false);
    await game.onLoad();

    // Run a little so there is motion to freeze.
    for (var i = 0; i < 120; i++) {
      game.update(1 / 60);
    }
    final running = game.state.time;
    expect(running, greaterThan(0), reason: 'the world should advance normally');

    game.uiPaused = true;
    for (var i = 0; i < 300; i++) {
      game.update(1 / 60);
    }
    expect(game.state.time, running, reason: 'time advanced while paused');

    game.uiPaused = false;
    for (var i = 0; i < 60; i++) {
      game.update(1 / 60);
    }
    expect(game.state.time, greaterThan(running), reason: 'resume did not restart the world');
  });

  test('pausing does not disturb run state', () async {
    final game = SpliceGame(seed: 11, enableAudio: false);
    await game.onLoad();
    for (var i = 0; i < 300; i++) {
      game.update(1 / 60);
    }
    final kills = game.state.kills;
    final level = game.state.level;
    final hp = game.state.hp;

    game.uiPaused = true;
    for (var i = 0; i < 600; i++) {
      game.update(1 / 60);
    }

    expect(game.state.kills, kills);
    expect(game.state.level, level);
    expect(game.state.hp, hp);
  });

  test('audio toggles flip synchronously so the UI can read them back', () {
    final sfx = Sfx();
    expect(sfx.soundEnabled, isTrue);
    expect(sfx.musicEnabled, isTrue);

    sfx.setSoundEnabled(false);
    expect(sfx.soundEnabled, isFalse);

    // Not awaited on purpose: the pause menu flips the flag and rebuilds
    // immediately, so the field must be correct before the future completes.
    sfx.setMusicEnabled(false);
    expect(sfx.musicEnabled, isFalse);

    sfx.setSoundEnabled(true);
    sfx.setMusicEnabled(true);
    expect(sfx.soundEnabled, isTrue);
    expect(sfx.musicEnabled, isTrue);
  });

  test('muted playback is a no-op rather than an error', () {
    final sfx = Sfx()..setSoundEnabled(false);
    // Never initialised, so there are no players at all — this must still be
    // safe, because audio init is allowed to fail without breaking the game.
    expect(() => sfx.play('hit'), returnsNormally);
    expect(() => sfx.play('nonexistent'), returnsNormally);
  });
}
