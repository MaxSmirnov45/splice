/// Platform advertising, selected at compile time.
///
/// The conditional import is what keeps `google_mobile_ads` out of the web
/// bundle entirely — importing it unconditionally would drag a native-only SDK
/// into a build that can never use it, and Poki forbids third-party ads in the
/// first place.
library;

export 'ads_api.dart';

export 'ads_stub.dart'
    if (dart.library.io) 'ads_mobile.dart'
    if (dart.library.js_interop) 'ads_web.dart';
