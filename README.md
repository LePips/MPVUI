# MPVUI

A SwiftUI video player backed by mpv, built on [MPVKit](https://github.com/mpvkit/MPVKit).

## Usage

```swift
import MPVUI
import SwiftUI

struct MyVideoPlayer: View {
    var body: some View {
        MPVVideoPlayer(player: .init(url: /* video url */))
    }
}
```

## Development

See [BUILD.md](Build/BUILD.md) for local development and building steps.
