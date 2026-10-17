# MPVUI

A Swift video player for SwiftUI and [Android](Android/README.md) Compose, backed by mpv.

## Usage

```swift
import MPVUI
import SwiftUI

struct MyVideoPlayer: View {

    @State
    private var player = MPVPlayer()

    let url: URL

    var body: some View {
        MPVVideoPlayer(player: player)
            .task(id: url) { player.load(url) }
    }
}
```

## Development

- [Architecture](Documentation/ARCHITECTURE.md): shared core, platform integration, and build diagrams.
- [Building](Build/BUILD.md): native libraries, local artifact selection, and release candidates.
- [Patches](Build/PATCHES.md): native changes and their purposes.
- [Rendering](Build/RENDERING.md): video output, high dynamic range, and subtitles.
- [Testing](Documentation/TESTING.md): shared core, platform integration, and consumer checks.
