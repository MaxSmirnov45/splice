import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ads_api.dart';

/// AdMob rewarded video, used on the app stores.
///
/// The session hooks inherited from [RewardedAdService] stay as no-ops: a
/// native store has no concept of gameplay markers or interstitials between
/// runs, and this game deliberately shows no non-rewarded ads.
class AdMobRewardedAds implements RewardedAdService {
  /// Google's public test ad units.
  ///
  /// Shipping with these is deliberate: they always fill, so the feature is
  /// testable without an AdMob account, and they earn nothing — far safer than
  /// accidentally serving live ads against someone else's unit ID. Override at
  /// build time once real units exist:
  ///   --dart-define=ADMOB_REWARDED_ANDROID=ca-app-pub-.../...
  static const _androidUnit = String.fromEnvironment(
    'ADMOB_REWARDED_ANDROID',
    defaultValue: 'ca-app-pub-3940256099942544/5224354917',
  );
  static const _iosUnit = String.fromEnvironment(
    'ADMOB_REWARDED_IOS',
    defaultValue: 'ca-app-pub-3940256099942544/1712485313',
  );

  @override
  void Function()? onAdOpened;
  @override
  void Function()? onAdClosed;

  /// The app stores have no host-level mute control; the OS volume is the
  /// only one, and it applies below the app.
  @override
  void Function(bool muted)? onHostMuteChanged;

  RewardedAd? _ad;
  bool _loading = false;
  int _failures = 0;

  static String get _unitId => Platform.isAndroid ? _androidUnit : _iosUnit;

  @override
  bool get isReady => _ad != null;

  @override
  Future<void> initialize() async {
    try {
      await MobileAds.instance.initialize();
      _load();
    } catch (e) {
      debugPrint('ads: initialize failed, revives disabled ($e)');
    }
  }

  void _load() {
    if (_loading || _ad != null) return;
    _loading = true;
    try {
      RewardedAd.load(
        adUnitId: _unitId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            _ad = ad;
            _loading = false;
            _failures = 0;
          },
          onAdFailedToLoad: (error) {
            _ad = null;
            _loading = false;
            _failures++;
            // Back off rather than hammering a failing network, but stay
            // capped so a long session recovers once connectivity returns.
            final delay =
                Duration(seconds: (1 << _failures.clamp(0, 6)).clamp(2, 64));
            Timer(delay, _load);
          },
        ),
      );
    } catch (e) {
      _loading = false;
      debugPrint('ads: load threw ($e)');
    }
  }

  @override
  Future<bool> show() async {
    final ad = _ad;
    if (ad == null) return false;
    _ad = null; // consumed either way; a new one loads on dismissal

    final completer = Completer<bool>();
    var earned = false;

    void finish(bool result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) => onAdOpened?.call(),
      onAdDismissedFullScreenContent: (ad) {
        onAdClosed?.call();
        ad.dispose();
        _load();
        finish(earned);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        onAdClosed?.call();
        ad.dispose();
        _load();
        finish(false);
      },
    );

    try {
      await ad.show(onUserEarnedReward: (_, _) => earned = true);
    } catch (e) {
      debugPrint('ads: show threw ($e)');
      finish(false);
    }

    // Never strand the player behind a fullscreen ad that failed to report.
    return completer.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () => earned,
    );
  }

  @override
  void dispose() {
    _ad?.dispose();
    _ad = null;
  }

  @override
  void loadingFinished() {}

  @override
  void gameplayStart() {}

  @override
  void gameplayStop() {}

  @override
  Future<void> commercialBreak() async {}
}

RewardedAdService createAdService() {
  try {
    if (Platform.isAndroid || Platform.isIOS) return AdMobRewardedAds();
  } catch (_) {
    // Platform is unavailable on some test hosts.
  }
  return const DisabledAds();
}
