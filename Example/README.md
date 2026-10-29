# MPVUI example

Cross platform example app using [Skip](https://skip.dev).

## Prerequisites

Install Xcode, Skip, and the [native library build dependencies](../Build/BUILD.md#android-libraries).

## Apple

Ensure the [selected native libraries](../Build/BUILD.md#apple-libraries) include your target platform.

## Android

Build the native libraries:

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
make build PLATFORM=android
```

The build includes both native architectures, which the example needs even when running on one device. Open `Example/Android` in Android Studio, select an Android 16+ emulator or device, and run the `app` configuration.

After changing native sources, rebuild the libraries before rebuilding the example. See [Android builds](../Build/BUILD.md#android-libraries) for incremental build options.

## Media

To bundle files, add them to `Example/Sources/MPVUIExample/Resources/Media` before building.
