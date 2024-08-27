# MPVUI
 
### 🚧 Work in progress 🛠️

`MPVUI` is a wrapper around mpv for more compatible audio and video media playback on iOS, tvOS, and macOS.

Currently utilizing [MPVKit](https://github.com/mpvkit/MPVKit) for easy mpv access through Swift Package Manager.

### Usage

The `MPVClient` object is core wrapper around mpv, containing commands to load, play, and customize media playback.

```swift
// mp3 example
let client = MPVClient()
try! client._command(.loadfile, arguments: "music.mp3", "replace")
client.play()
```

### Construction

- [ ] player views for video playback
- [ ] API around commands
- [ ] better event observation