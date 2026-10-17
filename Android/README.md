# Android

> [!WARNING]
> Android implementation is currently a work in progress.

A Kotlin player with video views for Compose and Android Views, backed by the shared Swift playback core. Supports Android 16+ on `arm64-v8a` and `x86_64`. The library includes its native dependencies and Swift runtime.

## Installation

Configure the [local Maven repository](../Build/BUILD.md#local-repository), then add the library to your app's `build.gradle.kts`. Use the version available in that repository:

```kotlin
dependencies {
    implementation("io.github.lepips:mpvui:0.7.0")
}
```

## Playback

Create `MPVPlayer(context)` once in a `ViewModel`, then pass it to the video view:

```kotlin
import android.net.Uri
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import mpvui.MPVPlayer
import mpvui.MPVVideoPlayer

@Composable
fun VideoPlayer(player: MPVPlayer, uri: Uri) {
    LaunchedEffect(player, uri) {
        player.load(uri)
    }

    MPVVideoPlayer(player, Modifier.fillMaxSize())
}
```

Close the player in `ViewModel.onCleared()`. Pause playback when the Activity stops unless it continues in picture in picture or a background playback service.
