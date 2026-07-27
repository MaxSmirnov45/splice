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

  /// Ads are requested on demand rather than preloaded, so readiness is simply
  /// whether the SDK initialised.
  @override
  bool get isReady => _initialised;

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

  @override
  Future<void> commercialBreak() => _requestAd('midgame');

  @override
  Future<bool> show() => _requestAd('rewarded');

  /// Requests an ad and resolves true only when it actually completed.
  ///
  /// The SDK reports via callbacks rather than a promise, so this bridges them
  /// into a future — with a timeout, because a callback that never fires would
  /// otherwise strand the player on a frozen screen forever.
  Future<bool> _requestAd(String type) async {
    if (!_initialised) return false;

    final wasRunning = _gameplayRunning;
    // Play must stop around any break, or the portal counts ad time as
    // engagement.
    gameplayStop();

    final completer = Completer<bool>();
    void finish(bool result) {
      if (completer.isCompleted) return;
      onAdClosed?.call();
      completer.complete(result);
    }

    try {
      final callbacks = JSObject();
      callbacks.setProperty('adFinished'.toJS, (() => finish(true)).toJS);
      callbacks.setProperty('adError'.toJS, ((JSAny? _, JSAny? __) => finish(false)).toJS);
      // Muting and pausing here rather than at request time is the portal's
      // documented requirement: a request can sit unfilled for some time
      // before anything actually appears on screen.
      callbacks.setProperty('adStarted'.toJS, (() => onAdOpened?.call()).toJS);
      _cgRequestAd(type.toJS, callbacks);
    } catch (e) {
      debugPrint('crazygames: requestAd threw ($e)');
      finish(false);
    }

    final result = await completer.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () => false,
    );
    if (wasRunning) gameplayStart();
    return result;
  }

  @override
  void dispose() {
    gameplayStop();
  }
}
