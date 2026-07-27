/// The host platform's advertising and session hooks.
///
/// The game talks to this and never to a specific ad SDK, so the same code
/// runs against AdMob on the stores, Poki on the web, and nothing at all in
/// tests. A host that cannot deliver a rewarded video simply reports
/// [isReady] false and the revive button is never offered.
abstract class RewardedAdService {
  /// Whether a rewarded video is loaded and can be shown right now.
  bool get isReady;

  Future<void> initialize();

  /// Shows the rewarded video. Resolves true only if the reward was actually
  /// earned; dismissing early must not grant it.
  Future<bool> show();

  void dispose();

  /// Called when an ad actually appears, and again when it goes away.
  ///
  /// Portals require the game to be muted and paused for the duration of an
  /// ad — not merely before requesting one, since a request may sit unfilled
  /// for a while before anything is shown. The host wires these to pausing the
  /// simulation and ducking audio.
  void Function()? onAdOpened;
  void Function()? onAdClosed;

  // --- session hooks -------------------------------------------------------
  //
  // Web portals want to know when the player is actually playing, so they can
  // avoid interrupting them and can measure engagement. Native stores have no
  // equivalent, so these default to doing nothing.

  /// Signals that loading has finished and the game is playable.
  void loadingFinished() {}

  /// Brackets active play. Called when a run starts and when it ends or is
  /// paused, so the portal never interrupts mid-run.
  void gameplayStart() {}

  void gameplayStop() {}

  /// A non-rewarded interstitial, shown between runs. Resolves when the player
  /// can continue, whether or not anything was displayed.
  Future<void> commercialBreak() async {}
}

/// Used where no ad host exists: tests, unsupported platforms, or a build with
/// advertising deliberately switched off.
class DisabledAds implements RewardedAdService {
  const DisabledAds();

  @override
  void Function()? get onAdOpened => null;
  @override
  set onAdOpened(void Function()? _) {}
  @override
  void Function()? get onAdClosed => null;
  @override
  set onAdClosed(void Function()? _) {}

  @override
  bool get isReady => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> show() async => false;

  @override
  void dispose() {}

  @override
  void loadingFinished() {}

  @override
  void gameplayStart() {}

  @override
  void gameplayStop() {}

  @override
  Future<void> commercialBreak() async {}
}
