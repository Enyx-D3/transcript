# Preserve Google Play Feature Delivery classes
-keep class com.google.android.play.feature.** { *; }
-dontwarn com.google.android.play.feature.**

# Preserve flutter_downloader classes
-keep class vn.hunghd.** { *; }
-dontwarn vn.hunghd.**

# Preserve WorkManager classes
-keep class androidx.work.** { *; }
-dontwarn androidx.work.**