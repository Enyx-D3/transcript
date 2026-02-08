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
# FFmpegKit
############################################################
-keep class com.arthenica.ffmpegkit.** { *; }
-dontwarn com.arthenica.ffmpegkit.**
-keep class com.arthenica.smartexception.** { *; }
-dontwarn com.arthenica.smartexception.**

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
