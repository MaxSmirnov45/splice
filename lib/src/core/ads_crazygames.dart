import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';

import 'ads_api.dart';

/// CrazyGames SDK bindings.
///
/// Loaded by a script tag injected at build time for the crazygames target.
/// Every call is guarded on the object existing, so the same bundle stays
/// playable when hosted anywhere else.
@JS('CrazyGames.SDK.init')
external JSPromise<JSAny?> _cgInit();

@JS('CrazyGames.SDK.game.loadingStart')
external void _cgLoadingStart();

@JS('CrazyGames.SDK.game.loadingStop')
external void _cgLoadingStop();

@JS('CrazyGames.SDK.game.gameplayStart')
external void _cgGameplayStart();

@JS('CrazyGames.SDK.game.gameplayStop')
external void _cgGameplayStop();

@JS('CrazyGames.SDK.ad.requestAd')
external void _cgRequestAd(JSString type, JSObject callbacks);

@JS('CrazyGames.SDK.game.addSettingsChangeListener')
external void _cgAddSettingsListener(JSFunction listener);

@JS('CrazyGames.SDK.game.removeSettingsChangeListener')
external void _cgRemoveSettingsListener(JSFunction listener);

bool get _sdkPresent {
  try {
    if (!globalContext.has('CrazyGames')) return false;
    final cg = globalContext.getProperty('CrazyGames'.toJS) as JSObject?;
    return cg != null && cg.has('SDK');
  } catch (_) {
    return false;
  }
}

/// CrazyGames-hosted advertising and session reporting.
class CrazyGamesAds implements RewardedAdService {
  bool _initialised = false;
  bool _gameplayRunning = false;

  @override
  void Function()? onAdOpened;
  @override
  void Function()? onAdClosed;
  @override
  void Function(bool muted)? onHostMuteChanged;

  /// Held so it can be removed on dispose — the SDK matches listeners by
  /// identity, and a fresh closure would never unregister the original.
  JSFunction? _settingsListener;

  /// Consecutive requests of each kind that produced no ad.
  ///
  /// Advertising is switched off entirely during a Basic launch, so every
  /// request goes unfilled — and an unfilled request costs a visible wait. Left
  /// unchecked that is six dead seconds on every single restart, and a revive
  /// button that is offered and then quietly does nothing. After two proven
  /// misses this stops asking: the player pays the wait once instead of
  /// forever, and the button stops promising something it cannot deliver.
  int _midgameMisses = 0;
  int _rewardedMisses = 0;

  /// Misses tolerated before a kind of ad is treated as unavailable. Two
  /// rather than one, so a single transient failure does not cost the player
  /// their revives for the whole session.
  static const int _missesBeforeGivingUp = 2;

  bool get _midgameAvailable => _midgameMisses < _missesBeforeGivingUp;
  bool get _rewardedAvailable => _rewardedMisses < _missesBeforeGivingUp;

  /// Ads are requested on demand rather than preloaded, so readiness is the
  /// SDK being up and rewarded ads not having proven themselves absent.
  @override
  bool get isReady => _initialised && _rewardedAvailable;

  @override
  Future<void> initialize() async {
    if (!_sdkPresent) {
      debugPrint('crazygames: SDK absent — running without portal integration');
      return;
    }
    try {
      await _cgInit().toDart;
      _initialised = true;
      _cgLoadingStart();
      _watchSettings();
    } catch (e) {
      debugPrint('crazygames: init failed ($e)');
      _initialised = false;
    }
  }

  @override
  void loadingFinished() {
    if (!_initialised) return;
    try {
      _cgLoadingStop();
    } catch (_) {}
  }

  @override
  void gameplayStart() {
    // Guarded against double-start: the portal expects balanced calls, and the
    // game raises these from several places (run start, resume, revive).
    if (!_initialised || _gameplayRunning) return;
    _gameplayRunning = true;
    try {
      _cgGameplayStart();
    } catch (_) {}
  }

  @override
  void gameplayStop() {
    if (!_initialised || !_gameplayRunning) return;
    _gameplayRunning = false;
    try {
      _cgGameplayStop();
    } catch (_) {}
  }

  /// Earliest point another interstitial may be requested.
  ///
  /// Portals space these out as a matter of policy, and asking on every
  /// restart also meant paying the unfilled-request wait every restart. A
  /// player who dies three times in a minute now sees at most one break.
  DateTime? _nextMidgameAllowed;

  /// How long to leave between interstitials.
  static const Duration _midgameInterval = Duration(minutes: 3);

  @override
  Future<void> commercialBreak() async {
    if (!_midgameAvailable) return;
    final now = DateTime.now();
    if (_nextMidgameAllowed != null && now.isBefore(_nextMidgameAllowed!)) {
      return;
    }
    _nextMidgameAllowed = now.add(_midgameInterval);
    await _requestAd('midgame');
  }

  @override
  Future<bool> show() {
    if (!_rewardedAvailable) return Future.value(false);
    return _requestAd('rewarded');
  }

  /// Seconds to wait for an ad to actually appear before giving up.
  ///
  /// An unfilled request can sit silently forever — which it does in the
  /// portal's own preview, where nothing serves. Waiting on it froze the
  /// button that asks for one: SPLICE AGAIN takes an interstitial on the way
  /// through, so the player pressed it and nothing happened at all.
  static const Duration _appearTimeout = Duration(seconds: 6);

  /// Once something is on screen it may legitimately run for a while, so the
  /// second wait is generous. It exists only so a callback that never arrives
  /// cannot strand the player on a frozen screen forever.
  static const Duration _finishTimeout = Duration(minutes: 3);

  /// Requests an ad and resolves true only when it actually completed.
  ///
  /// The SDK reports via callbacks rather than a promise, so this bridges them
  /// into a future — in two stages, because "no ad was available" and "the ad
  /// is still playing" are indistinguishable from a single timeout.
  Future<bool> _requestAd(String type) async {
    if (!_initialised) return false;

    final wasRunning = _gameplayRunning;
    // Play must stop around any break, or the portal counts ad time as
    // engagement.
    gameplayStop();

    final appeared = Completer<void>();
    final completer = Completer<bool>();

    void finish(bool result) {
      if (completer.isCompleted) return;
      // Only if something was actually shown. Pairing a close with an open
      // that never happened would resume audio nobody paused.
      if (appeared.isCompleted) onAdClosed?.call();
      completer.complete(result);
    }

    try {
      final callbacks = JSObject();
      callbacks.setProperty('adFinished'.toJS, (() => finish(true)).toJS);
      callbacks.setProperty(
        'adError'.toJS,
        ((JSAny? _, JSAny? reason) => finish(false)).toJS,
      );
      // Muting and pausing here rather than at request time is the portal's
      // documented requirement: a request can sit unfilled for some time
      // before anything actually appears on screen.
      callbacks.setProperty(
        'adStarted'.toJS,
        (() {
          if (!appeared.isCompleted) appeared.complete();
          onAdOpened?.call();
        }).toJS,
      );
      _cgRequestAd(type.toJS, callbacks);
    } catch (e) {
      debugPrint('crazygames: requestAd threw ($e)');
      finish(false);
    }

    // First wait: did anything reach the screen?
    if (!completer.isCompleted) {
      await Future.any([
        appeared.future,
        completer.future,
        Future<void>.delayed(_appearTimeout),
      ]);
    }

    var result = false;
    if (appeared.isCompleted) {
      // Something reached the screen, so this request was filled whatever
      // happens next.
      _noteHit(type);
      result = completer.isCompleted
          ? await completer.future
          // Second wait: it is on screen, so let it run.
          : await completer.future.timeout(
              _finishTimeout,
              onTimeout: () => false,
            );
    } else {
      // Either an error came back before anything was shown, or nothing was
      // served at all. Both mean the player got no ad.
      _noteMiss(type);
      if (!completer.isCompleted) {
        debugPrint(
          'crazygames: no $type ad appeared within '
          '${_appearTimeout.inSeconds}s — continuing',
        );
      }
    }

    if (wasRunning) gameplayStart();
    return result;
  }

  void _noteHit(String type) {
    if (type == 'rewarded') {
      _rewardedMisses = 0;
    } else {
      _midgameMisses = 0;
    }
  }

  void _noteMiss(String type) {
    if (type == 'rewarded') {
      _rewardedMisses++;
      if (!_rewardedAvailable) {
        debugPrint(
          'crazygames: rewarded ads unavailable — no longer offering '
          'anything that depends on one',
        );
      }
    } else {
      _midgameMisses++;
      if (!_midgameAvailable) {
        debugPrint(
          'crazygames: midgame ads unavailable — no longer requesting',
        );
      }
    }
  }

  /// Mirrors the portal's own mute control into the game.
  ///
  /// The current value is read once up front as well as subscribed to: a
  /// player who muted the portal on a previous game arrives with it already
  /// on, and would otherwise hear the game until they toggled it twice.
  void _watchSettings() {
    _report(_readMuteAudio());
    try {
      final listener = ((JSAny? _) => _report(_readMuteAudio())).toJS;
      _settingsListener = listener;
      _cgAddSettingsListener(listener);
    } catch (e) {
      debugPrint('crazygames: settings listener unavailable ($e)');
    }
  }

  void _report(bool? muted) {
    if (muted == null) return;
    onHostMuteChanged?.call(muted);
  }

  /// Reads `CrazyGames.SDK.game.settings.muteAudio`, or null if the shape is
  /// not what the documentation describes.
  bool? _readMuteAudio() {
    try {
      final cg = globalContext.getProperty('CrazyGames'.toJS) as JSObject?;
      final sdk = cg?.getProperty('SDK'.toJS) as JSObject?;
      final game = sdk?.getProperty('game'.toJS) as JSObject?;
      final settings = game?.getProperty('settings'.toJS) as JSObject?;
      final value = settings?.getProperty('muteAudio'.toJS);
      if (value == null) return null;
      return (value as JSBoolean).toDart;
    } catch (e) {
      debugPrint('crazygames: could not read muteAudio ($e)');
      return null;
    }
  }

  @override
  void dispose() {
    gameplayStop();
    final listener = _settingsListener;
    if (listener != null) {
      _settingsListener = null;
      try {
        _cgRemoveSettingsListener(listener);
      } catch (_) {}
    }
  }
}
