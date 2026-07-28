import 'package:audioplayers/audioplayers.dart';

/// Sound effect playback.
///
/// A survivors-like fires sounds far faster than a single player can retrigger
/// them, so each effect gets a small round-robin pool of players plus a
/// minimum interval. Without the throttle, a wide aura clearing a dense wave
/// would try to start dozens of identical hits in one frame — which on a real
/// device is both inaudible mush and a genuine performance problem.
class Sfx {
  /// Minimum gap between repeats of the same effect, in seconds.
  ///
  /// Deliberately generous. Every play crosses a platform channel, and on a
  /// build where the platform thread is merged with the UI thread that cost
  /// lands directly on frame time. The earlier values (~40ms) let the game
  /// issue roughly ninety plays a second and were the single largest source
  /// of stutter in the whole app — far outweighing anything in the renderer.
  /// Nobody can distinguish individual hits at 40ms anyway.
  static const Map<String, double> _throttle = {
    'shoot': 0.11,
    'hit': 0.13,
    'kill': 0.11,
    'pickup': 0.10,
    'hurt': 0.25,
    'levelup': 0.5,
    'splice': 0.2,
    'adapt': 1.0,
  };

  /// Hard ceiling on plays per second across all effects, regardless of the
  /// per-effect throttles. A dense wave can trip several different sounds in
  /// the same instant; this bounds the worst case.
  static const int _maxPlaysPerSecond = 14;

  /// The effects the game actually plays, and how many voices each may use.
  ///
  /// The high-frequency combat sounds — shoot, hit, kill, pickup — are
  /// deliberately absent. Every play crosses a platform channel, and on iOS
  /// that lands on the thread that also drives presentation, so constant
  /// combat audio produced a persistent micro-stutter that no amount of
  /// throttling fully removed. Rare, informative sounds cost nothing at this
  /// frequency and carry almost all of the value.
  ///
  /// Their WAVs are still generated and bundled, so re-enabling one is a
  /// matter of adding it back to this map.
  static const Map<String, int> _voices = {
    'hurt': 1,
    'levelup': 1,
    'splice': 1,
    'adapt': 1,
  };

  /// Per-effect trim, so nothing has to be re-synthesised to rebalance.
  static const Map<String, double> _gain = {
    'shoot': 0.22,
    'hit': 0.26,
    'kill': 0.34,
    'pickup': 0.30,
    'hurt': 0.75,
    'levelup': 0.65,
    'splice': 0.60,
    'adapt': 0.55,
  };

  final Map<String, List<AudioPlayer>> _pools = {};
  final Map<String, int> _cursor = {};
  final Map<String, double> _lastPlayed = {};

  double _windowStart = 0;
  int _playsThisWindow = 0;

  AudioPlayer? _ambient;

  /// Master levels, 0..1. Zero is off; there is no separate mute flag, so the
  /// UI only has to manage one value per channel.
  double _soundVolume = 0.85;
  double _musicVolume = 0.55;

  /// Silenced by the host platform rather than by the player.
  ///
  /// Portals carry their own mute control and require it to override the
  /// game's settings, so this gates output while leaving the player's levels
  /// untouched — unmuting has to restore exactly the sliders they set, not a
  /// default.
  bool _hostMuted = false;

  double get soundVolume => _soundVolume;
  double get musicVolume => _musicVolume;

  /// The levels actually sent to the players.
  double get _outSound => _hostMuted ? 0.0 : _soundVolume;
  double get _outMusic => _hostMuted ? 0.0 : _musicVolume;

  bool get soundEnabled => _outSound > 0.001;
  bool get musicEnabled => _outMusic > 0.001;

  /// Applies the host's mute state. Idempotent, since a portal may re-send the
  /// same settings for unrelated reasons.
  Future<void> setHostMuted(bool muted) async {
    if (_hostMuted == muted) return;
    _hostMuted = muted;
    await _applySoundVolume();
    await _applyMusicVolume();
  }

  bool _ready = false;

  final Stopwatch _clock = Stopwatch()..start();

  double get _now => _clock.elapsedMilliseconds / 1000.0;

  Future<void> init() async {
    // Session configuration gets its own guard on purpose. Folding it into the
    // block below meant one throw from this call left `_ready` false and
    // silently killed *all* audio — the game ran perfectly and completely
    // mute, which is a miserable failure mode to debug.
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          iOS: AudioContextIOS(
            // `playback`, not `ambient`: ambient honours the hardware silent
            // switch, so a muted phone kills the game's audio entirely. Games
            // are expected to play through it.
            category: AVAudioSessionCategory.playback,
            options: const {AVAudioSessionOptions.mixWithOthers},
          ),
          android: const AudioContextAndroid(
            isSpeakerphoneOn: false,
            stayAwake: false,
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.game,
            audioFocus: AndroidAudioFocus.none,
          ),
        ),
      );
    } catch (_) {
      // Defaults are fine; carry on and still load the players.
    }

    try {
      for (final entry in _voices.entries) {
        final players = <AudioPlayer>[];
        for (var i = 0; i < entry.value; i++) {
          final p = AudioPlayer(playerId: '${entry.key}_$i')
            ..setReleaseMode(ReleaseMode.stop);
          // Default player mode, not lowLatency: the low-latency path does not
          // reliably support seek, and rewinding is what lets a finished voice
          // play a second time. A voice that cannot rewind goes permanently
          // silent after its first use.
          await p.setSource(AssetSource('sfx/${entry.key}.wav'));
          // Volume is set once here, not on every play. Doing it per play
          // tripled the number of platform-channel calls for no benefit —
          // these levels never change at runtime.
          await p.setVolume((_gain[entry.key] ?? 0.5) * _outSound);
          players.add(p);
        }
        _pools[entry.key] = players;
        _cursor[entry.key] = 0;
      }
      _ready = true;
    } catch (_) {
      // Audio is never worth failing a launch over; the game runs silent.
      _ready = false;
    }
  }

  /// Effects worth spending the frame's audio budget on first.
  ///
  /// When more sounds are requested in one frame than can be dispatched, the
  /// ones carrying real information win over ambient combat chatter.
  static const List<String> _priority = ['levelup', 'hurt', 'splice', 'adapt'];

  /// At most this many sounds actually reach the platform per frame.
  ///
  /// The simulation can raise a dozen events in a single tick. Dispatching
  /// them inline meant an unbounded number of channel calls landing inside one
  /// frame; queueing and capping keeps the per-frame audio cost constant.
  static const int _maxPlaysPerFrame = 2;

  final Set<String> _pending = <String>{};

  /// Records that [id] happened. Cheap enough to call from the hot loop —
  /// it only touches a set. Nothing reaches the platform until [flush].
  void request(String id) {
    // Effects that are not configured are dropped here, at a const map lookup,
    // before they can allocate or reach the queue. The simulation still
    // reports every event; the audio layer decides none of them are worth a
    // platform call.
    if (!soundEnabled || !_voices.containsKey(id)) return;
    _pending.add(id);
  }

  /// Dispatches queued sounds. Called once per frame by the game loop.
  void flush() {
    if (_pending.isEmpty) return;
    if (!_ready || !soundEnabled) {
      _pending.clear();
      return;
    }

    var dispatched = 0;
    for (final id in _priority) {
      if (dispatched >= _maxPlaysPerFrame) break;
      if (!_pending.remove(id)) continue;
      if (_playNow(id)) dispatched++;
    }
    // Anything not dispatched this frame is dropped rather than carried over;
    // a stale hit sound arriving late is worse than no sound.
    _pending.clear();
  }

  /// Immediate playback, bypassing the queue. Used for UI sounds that happen
  /// outside the game loop.
  void play(String id, {double volume = 1.0}) {
    if (!_ready || !soundEnabled) return;
    _playNow(id);
  }

  bool _playNow(String id) {
    if (!allowPlay(id)) return false;

    final pool = _pools[id];
    if (pool == null || pool.isEmpty) return false;
    final i = _cursor[id]!;
    _cursor[id] = (i + 1) % pool.length;
    final player = pool[i];

    // Rewind, then play. A voice that has reached the end will not restart on
    // resume() alone, so the seek is required — but the two are issued
    // independently rather than chained. Chaining meant a failed or slow seek
    // silently swallowed the playback that was supposed to follow it, and
    // calls on one channel are processed in order anyway.
    player.seek(Duration.zero).catchError((_) {});
    player.resume().catchError((_) {});
    return true;
  }

  /// The throttling decision, split out so it can be exercised directly.
  /// Mutates the rate-limit state, exactly as a real play would.
  bool allowPlay(String id) {
    final now = _now;

    // Global rate limit first, so a burst of different effects in one frame
    // cannot bypass the per-effect throttles.
    if (now - _windowStart >= 1.0) {
      _windowStart = now;
      _playsThisWindow = 0;
    }
    if (_playsThisWindow >= _maxPlaysPerSecond) return false;

    final gap = _throttle[id] ?? 0.1;
    if (now - (_lastPlayed[id] ?? -999.0) < gap) return false;
    _lastPlayed[id] = now;
    _playsThisWindow++;
    return true;
  }

  /// Exposed so tests can assert the ceilings without a platform plugin.
  static int get maxPlaysPerSecond => _maxPlaysPerSecond;
  static int get maxPlaysPerFrame => _maxPlaysPerFrame;

  /// Whether the players loaded. False means the game is running mute.
  bool get isReady => _ready;

  /// Number of distinct effects queued but not yet dispatched.
  int get pendingCount => _pending.length;

  /// Ordered highest priority first.
  static List<String> get priorityOrder => _priority;

  /// Seeds the levels before [init] runs, so saved settings are applied when
  /// the players are first configured rather than re-sent afterwards.
  void primeVolumes({double? sound, double? music}) {
    if (sound != null) _soundVolume = sound.clamp(0.0, 1.0);
    if (music != null) _musicVolume = music.clamp(0.0, 1.0);
  }

  /// Sets the effects level.
  ///
  /// Volume is pushed to the players here rather than on every play: per-play
  /// volume calls were a measurable share of the audio cost, and the level
  /// only changes when someone drags a slider on a paused game.
  Future<void> setSoundVolume(double value) async {
    _soundVolume = value.clamp(0.0, 1.0);
    await _applySoundVolume();
  }

  Future<void> _applySoundVolume() async {
    if (!_ready) return;
    for (final entry in _pools.entries) {
      final gain = (_gain[entry.key] ?? 0.5) * _outSound;
      for (final p in entry.value) {
        try {
          await p.setVolume(gain);
        } catch (_) {
          // A single player refusing is not worth failing the whole change.
        }
      }
    }
  }

  /// Sets the music level. Zero stops the loop outright rather than leaving it
  /// running silently and holding a player slot.
  Future<void> setMusicVolume(double value) async {
    _musicVolume = value.clamp(0.0, 1.0);
    await _applyMusicVolume();
  }

  Future<void> _applyMusicVolume() async {
    if (_outMusic <= 0.001) {
      await stopAmbient();
      return;
    }
    if (_ambient == null) {
      await startAmbient();
      return;
    }
    try {
      await _ambient!.setVolume(_outMusic);
    } catch (_) {
      // Ignore; the level applies on the next start.
    }
  }

  /// Convenience wrappers for callers that only care about on/off.
  void setSoundEnabled(bool enabled) => _soundVolume = enabled ? 0.85 : 0.0;

  Future<void> setMusicEnabled(bool enabled) =>
      setMusicVolume(enabled ? 0.55 : 0.0);

  Future<void> startAmbient() async {
    // Only ever construct a player once init succeeded. Creating one when the
    // platform plugin is missing (headless tests, unsupported host) throws
    // from an internal unawaited future, which no try/catch here can contain.
    if (!_ready || !musicEnabled || _ambient != null) return;
    try {
      _ambient = AudioPlayer(playerId: 'ambient')..setReleaseMode(ReleaseMode.loop);
      await _ambient!.setVolume(_outMusic);
      await _ambient!.play(AssetSource('sfx/ambient.m4a'));
    } catch (_) {
      _ambient = null;
    }
  }

  /// Silences the music for an external interruption, such as a fullscreen ad.
  ///
  /// Deliberately separate from [setMusicEnabled]: this must not touch the
  /// player's own music preference, or restoring afterwards would un-mute
  /// someone who had chosen silence. Pauses rather than stops, so the loop
  /// resumes where it left off instead of restarting the track.
  Future<void> pauseAmbient() async {
    try {
      await _ambient?.pause();
    } catch (_) {
      // Nothing playing, or the backend is unavailable.
    }
  }

  /// Restores music after an interruption, honouring the player's setting.
  Future<void> resumeAmbient() async {
    if (!musicEnabled) return;
    try {
      await _ambient?.resume();
    } catch (_) {
      // Nothing to resume.
    }
  }

  Future<void> stopAmbient() async {
    await _ambient?.stop();
    await _ambient?.dispose();
    _ambient = null;
  }

  Future<void> dispose() async {
    await stopAmbient();
    for (final pool in _pools.values) {
      for (final p in pool) {
        await p.dispose();
      }
    }
    _pools.clear();
  }
}
