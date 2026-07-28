import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/audio.dart';

/// Portals carry their own mute control and require it to override the game's
/// settings. Overriding is the easy half; the half that goes wrong is what
/// happens when it is switched back off.
void main() {
  test('a host mute silences output without disturbing the levels', () async {
    final sfx = Sfx();
    sfx.primeVolumes(sound: 0.4, music: 0.2);

    await sfx.setHostMuted(true);
    expect(sfx.soundEnabled, isFalse);
    expect(sfx.musicEnabled, isFalse);
    expect(sfx.soundVolume, 0.4,
        reason: 'the player\'s own sliders must survive being muted');
    expect(sfx.musicVolume, 0.2);

    await sfx.setHostMuted(false);
    expect(sfx.soundEnabled, isTrue);
    expect(sfx.musicEnabled, isTrue);
    expect(sfx.soundVolume, 0.4,
        reason: 'unmuting must restore what they set, not a default');
    expect(sfx.musicVolume, 0.2);
  });

  test('a level set while muted takes effect on unmute, not before', () async {
    final sfx = Sfx();
    await sfx.setHostMuted(true);
    await sfx.setMusicVolume(0.9);

    expect(sfx.musicVolume, 0.9, reason: 'the setting is still recorded');
    expect(sfx.musicEnabled, isFalse, reason: 'but the host still wins');

    await sfx.setHostMuted(false);
    expect(sfx.musicEnabled, isTrue);
  });

  test('muting a game the player already silenced changes nothing', () async {
    final sfx = Sfx();
    sfx.primeVolumes(sound: 0, music: 0);
    await sfx.setHostMuted(true);
    await sfx.setHostMuted(false);
    expect(sfx.soundEnabled, isFalse,
        reason: 'their own choice of silence must not be undone');
    expect(sfx.musicEnabled, isFalse);
  });
}
