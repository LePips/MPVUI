# Skip places these dependencies in the target app, so AGP omits them from the
# test APK. Keep their entry points only while instrumenting a release build.
-keep class androidx.test.** { *; }
-keep class androidx.tracing.** { *; }
-keep class kotlin.** { *; }
-keep class org.junit.** { *; }
-keep class junit.** { *; }
-keep class org.hamcrest.** { *; }

# The separately compiled UI tests inspect native player snapshots. R8 may
# otherwise inline these accessors out of the target APK before mapping tests.
-keepclassmembers,allowobfuscation class mpvui.** {
    public *** get*();
    public boolean is*();
}
# Caption geometry checks locate the native view by its runtime class name.
-keepnames class mpvui.CaptionView
-keepclassmembers,allowobfuscation interface kotlinx.coroutines.flow.StateFlow {
    public *** getValue();
}
