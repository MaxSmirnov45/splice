import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';

import 'ads_api.dart';
import 'ads_crazygames.dart';

/// Poki SDK bindings.
///
/// Loaded by a script tag in web/index.html. Every call is guarded on the
/// object actually existing, because the game must stay playable when it is
/// hosted anywhere other than Poki — a local build, itch.io, or a plain static
/// host — where the SDK simply is not there.
@JS('PokiSDK.init')
external JSPromise<JSAny?> _pokiInit();

@JS('PokiSDK.gameLoadingFinished')
external void _pokiLoadingFinished();

@JS('PokiSDK.gameplayStart')
external void _pokiGameplayStart();

@JS('PokiSDK.gameplayStop')
external void _pokiGameplayStop();

@JS('PokiSDK.commercialBreak')
external JSPromise<JSAny?> _pokiCommercialBreak();

@JS('PokiSDK.rewardedBreak')
external JSPromise<JSBoolean> _pokiRewardedBreak();

bool get _sdkPresent {
  try {
    return globalContext.has('PokiSDK');
  } catch (_) {
    return false;
  }
}

/// Poki-hosted advertising and session reporting.
class PokiAds implements RewardedAdService {
  bool _initialised = false;
  bool _gameplayRunning = false;

  /// Poki's rewarded break is requested on demand rather than preloaded, so
  /// there is nothing to poll — availability is simply whether the SDK exists.
  @override
  bool get isReady => _initialised;

  @override
  Future<void> initialize() async {
    if (!_sdkPresent) {
      debugPrint('poki: SDK absent — running without portal integration');
      return;
    }
    try {
      await _pokiInit().toDart;
      _initialised = true;
    } catch (e) {
      // A failed init must not take the game down with it.
      debugPrint('poki: init failed ($e)');
      _initialised = false;
    }
  }

  @override
  void loadingFinished() {
    if (!_sdkPresent) return;
    try {
      _pokiLoadingFinished();
    } catch (_) {}
  }

  @override
  void gameplayStart() {
    // Guarded against double-start: the portal expects these to be balanced,
    // and the game raises them from several places (run start, resume, revive).
    if (!_sdkPresent || _gameplayRunning) return;
    _gameplayRunning = true;
    try {
      _pokiGameplayStart();
    } catch (_) {}
  }

  @override
  void gameplayStop() {
    if (!_sdkPresent || !_gameplayRunning) return;
    _gameplayRunning = false;
    try {
      _pokiGameplayStop();
    } catch (_) {}
  }

  @override
  Future<void> commercialBreak() async {
    if (!_sdkPresent) return;
    // Play must be stopped around any break, or the portal counts ad time as
    // engagement and may refuse to show anything.
    final wasRunning = _gameplayRunning;
    gameplayStop();
    try {
      await _pokiCommercialBreak().toDart;
    } catch (_) {
      // Blocked, skipped, or failed — either way the player continues.
    }
    if (wasRunning) gameplayStart();
  }

  @override
  Future<bool> show() async {
    if (!_sdkPresent) return false;
    final wasRunning = _gameplayRunning;
    gameplayStop();
    var earned = false;
    try {
      final result = await _pokiRewardedBreak().toDart;
      earned = result.toDart;
    } catch (_) {
      earned = false;
    }
    if (wasRunning) gameplayStart();
    return earned;
  }

  @override
  void dispose() {
    gameplayStop();
  }
}

/// Picks the portal implementation by detecting which SDK the page loaded.
///
/// Detection at runtime rather than a build flag: the same bundle then works
/// on Poki, on CrazyGames, and standalone on itch or GitHub Pages, where it
/// simply runs without a portal. One less build variant to get wrong.
RewardedAdService createAdService() {
  if (_sdkPresent) return PokiAds();
  if (_crazyGamesPresent) return CrazyGamesAds();
  return const DisabledAds();
}

bool get _crazyGamesPresent {
  try {
    return globalContext.has('CrazyGames');
  } catch (_) {
    return false;
  }
}
