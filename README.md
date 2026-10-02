# MPVUI

A SwiftUI video player backed by mpv, built on [MPVKit](https://github.com/mpvkit/MPVKit).

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

- [Building](Build/BUILD.md): native libraries, local artifact selection, and release candidates.
- [Patches](Build/PATCHES.md): native changes and their purposes.
- [Rendering](Build/RENDERING.md): video outputs, HDR, PiP, subtitles, and fonts.
- [Testing](TESTING.md): automated tests, generated media, and device checks.
