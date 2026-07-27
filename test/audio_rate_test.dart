import 'package:flutter_test/flutter_test.dart';
import 'package:splice/src/core/audio.dart';

/// Sound playback is rate limited because each play crosses a platform
/// channel, and on builds where the platform thread is merged with the UI
/// thread that cost lands straight on frame time. Unthrottled combat audio was
/// the single largest source of stutter in the game.
void main() {
  test('a burst cannot exceed the per-second ceiling', () {
    final sfx = Sfx();
    var allowed = 0;
    // Far more attempts than any real frame could generate.
    for (var i = 0; i < 5000; i++) {
      if (sfx.allowPlay(i.isEven ? 'levelup' : 'hurt')) allowed++;
    }
    expect(allowed, lessThanOrEqualTo(Sfx.maxPlaysPerSecond),
        reason: 'the global ceiling must bound a same-instant burst');
    expect(allowed, greaterThan(0), reason: 'but some audio must still play');
  });

  test('one effect cannot monopolise the budget', () {
    final sfx = Sfx();
    var allowed = 0;
    for (var i = 0; i < 2000; i++) {
      if (sfx.allowPlay('levelup')) allowed++;
    }
    // Per-effect throttle is far stricter than the global ceiling.
    expect(allowed, lessThanOrEqualTo(2));
  });

  test('muting stops playback entirely', () {
    final sfx = Sfx()..setSoundEnabled(false);
    expect(() => sfx.play('hit'), returnsNormally);
    expect(sfx.soundEnabled, isFalse);
  });

  queueTests();
  interruptionTests();
}

/// Sound events are queued by the simulation and dispatched once per frame,
/// so a single tick raising a dozen events cannot put a dozen platform calls
/// inside one frame.
void queueTests() {
  test('high-frequency combat effects never reach the queue', () {
    final sfx = Sfx();
    for (var i = 0; i < 500; i++) {
      sfx.request('hit');
      sfx.request('kill');
      sfx.request('shoot');
      sfx.request('pickup');
    }
    // Dropped at the earliest possible point; these are the sounds whose
    // frequency caused the stutter.
    expect(sfx.pendingCount, 0);
  });

  test('rare informative effects still queue, and deduplicate', () {
    final sfx = Sfx();
    for (var i = 0; i < 500; i++) {
      sfx.request('levelup');
      sfx.request('hurt');
    }
    expect(sfx.pendingCount, 2);
  });

  test('flush always drains the queue', () {
    final sfx = Sfx();
    sfx.request('hurt');
    sfx.request('levelup');
    expect(sfx.pendingCount, greaterThan(0));
    sfx.flush();
    // Stale sounds are dropped rather than carried into the next frame.
    expect(sfx.pendingCount, 0);
  });

  test('muting discards queued sound', () {
    final sfx = Sfx()..setSoundEnabled(false);
    sfx.request('levelup');
    expect(sfx.pendingCount, 0);
  });

  test('informative sounds outrank combat chatter', () {
    final order = Sfx.priorityOrder;
    expect(order.indexOf('levelup'), lessThan(order.indexOf('adapt')));
    expect(order.indexOf('hurt'), lessThan(order.indexOf('splice')));
    expect(Sfx.maxPlaysPerFrame, lessThanOrEqualTo(3),
        reason: 'per-frame dispatch must stay bounded and small');
  });
}

/// Music must duck for a fullscreen ad and come back afterwards — without
/// overriding the player's own mute setting.
void interruptionTests() {
  test('ducking is safe with no audio backend', () async {
    final sfx = Sfx();
    // Never initialised, so there is no player at all. Both calls must be
    // no-ops rather than throwing into the revive flow.
    await sfx.pauseAmbient();
    await sfx.resumeAmbient();
    expect(sfx.musicEnabled, isTrue);
  });

  test('ducking does not change the player preference', () async {
    final sfx = Sfx();
    await sfx.pauseAmbient();
    // A pause for an ad is not the same as the player choosing silence.
    expect(sfx.musicEnabled, isTrue,
        reason: 'an interruption must not rewrite the music setting');
    await sfx.resumeAmbient();
    expect(sfx.musicEnabled, isTrue);
  });

  test('resume respects a player who muted the music', () async {
    final sfx = Sfx();
    await sfx.setMusicEnabled(false);
    await sfx.pauseAmbient();
    await sfx.resumeAmbient();
    // Restoring after an ad must not un-mute someone who chose silence.
    expect(sfx.musicEnabled, isFalse);
  });
}
