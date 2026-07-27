# Flutter's engine entry points are reached via JNI, so R8 cannot see them.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# audioplayers resolves platform classes reflectively.
-keep class xyz.luan.audioplayers.** { *; }

# Flutter's embedding references Play Core's deferred-component API, but this
# app ships as a single module and never loads a dynamic feature. The classes
# are genuinely absent, so tell R8 not to treat that as an error rather than
# adding a dependency we do not use.
-dontwarn com.google.android.play.core.**
