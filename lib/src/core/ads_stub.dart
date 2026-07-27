import 'ads_api.dart';

/// Fallback for hosts with no advertising support at all.
RewardedAdService createAdService() => const DisabledAds();
