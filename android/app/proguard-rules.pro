############################################################
# Flutter core + plugin registration (CRITICAL)
############################################################
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

-keep class **.GeneratedPluginRegistrant { *; }

# Keep all Flutter plugin implementations so registration can't be stripped
-keep class * implements io.flutter.embedding.engine.plugins.FlutterPlugin { *; }
-keep class * implements io.flutter.embedding.engine.plugins.activity.ActivityAware { *; }

############################################################
# App-specific native code
############################################################
-keep class com.enyxd.transcript.AudioConverter { *; }

############################################################
# Android components instantiated by name (CRITICAL for bg)
############################################################
-keep class * extends androidx.work.ListenableWorker { *; }
-keep class * extends android.app.Service { *; }
-keep class * extends android.content.BroadcastReceiver { *; }

############################################################
# flutter_foreground_task
############################################################
-keep class com.pravera.flutter_foreground_task.** { *; }
-dontwarn com.pravera.flutter_foreground_task.**

############################################################
# background_downloader
############################################################
-keep class com.bbflight.background_downloader.** { *; }
-dontwarn com.bbflight.background_downloader.**

############################################################
# permission_handler
############################################################
-keep class com.baseflow.permissionhandler.** { *; }
-dontwarn com.baseflow.permissionhandler.**

############################################################
# google_sign_in + Google Play Services
############################################################
-keep class io.flutter.plugins.googlesignin.** { *; }
-dontwarn io.flutter.plugins.googlesignin.**
-dontwarn com.google.android.gms.**
-keep class com.google.android.gms.** { *; }

############################################################
# in_app_purchase / BillingClient
############################################################
-dontwarn com.android.billingclient.**
-keep class com.android.billingclient.** { *; }

############################################################
# ObjectBox
############################################################
-keep class io.objectbox.** { *; }
-dontwarn io.objectbox.**

############################################################
# OkHttp / Okio / annotations
############################################################
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.jetbrains.annotations.**

############################################################
# Honor @Keep
############################################################
-keep @androidx.annotation.Keep class * { *; }
-keepclassmembers class * {
  @androidx.annotation.Keep *;
}

############################################################
# shared_preferences_android (CRITICAL - fixes Pigeon channel-error)
############################################################

# Keep the plugin class so it can be registered
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-dontwarn io.flutter.plugins.sharedpreferences.**
-keep class io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin { *; }

# Keep Pigeon-generated API classes used by shared_preferences_android
# (This matches your failing channel name)
-keep class dev.flutter.pigeon.shared_preferences_android.** { *; }
-dontwarn dev.flutter.pigeon.shared_preferences_android.**

############################################################
# Pigeon umbrella (fixes release channel stripping)
############################################################
-keep class dev.flutter.pigeon.** { *; }
-dontwarn dev.flutter.pigeon.**

# Extra safe: keep flutter plugin classes under io.flutter.plugins.*
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.plugins.**


############################################################
# Pigeon-generated channels (keep)
############################################################
-keep class dev.flutter.pigeon.** { *; }
-dontwarn dev.flutter.pigeon.**

############################################################
# shared_preferences_android
############################################################
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-dontwarn io.flutter.plugins.sharedpreferences.**
-keep class dev.flutter.pigeon.shared_preferences_android.** { *; }
-dontwarn dev.flutter.pigeon.shared_preferences_android.**

############################################################
# path_provider_android (you had channel-error before)
############################################################
-keep class io.flutter.plugins.pathprovider.** { *; }
-dontwarn io.flutter.plugins.pathprovider.**
-keep class dev.flutter.pigeon.path_provider_android.** { *; }
-dontwarn dev.flutter.pigeon.path_provider_android.**
