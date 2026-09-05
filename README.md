# MPVUI

mpv for SwiftUI, utilizing [MPVKit](https://github.com/mpvkit/MPVKit).

## Usage

`MPVPlayer` handles media playback. Create one for audio playback or pass it to
an `MPVVideoPlayer` for video playback.

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