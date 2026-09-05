# Build

Builds mpv, FFmpeg, and dependencies into one `Libmpv.xcframework.zip`.
Run commands from the repository root.

Requires the Xcode version in [Inputs.lock.json](Inputs.lock.json) and Python 3.10+.
Publishing also requires GitHub CLI authentication (`gh auth login`).

```sh
Build/mpvbuild doctor --bootstrap
```

## Local development

```sh
Build/mpvbuild build --profile dev
Build/mpvbuild use local --artifact /path/to/printed/candidate

# Switch back to the published artifact.
Build/mpvbuild use remote
```

Defaults to macOS and your Mac’s architecture. For iOS device and simulator:

```sh
Build/mpvbuild build --profile dev --slices ios,isimulator --arch arm64
```

Refresh package resolution in Xcode after switching artifacts.

## Release

Choose a new version. Replace candidate and bundle paths with the printed paths.

```sh
VERSION=0.2.0
Build/mpvbuild build --profile release --tag "$VERSION"
cp /path/to/printed/candidate/Artifacts.lock.json Build/Artifacts.lock.json
Build/mpvbuild generate

# Commit and push changes, then create and push the "$VERSION" tag.
Build/mpvbuild release candidate --profile release --tag "$VERSION"
Build/mpvbuild release publish --candidate /path/to/printed/bundle
```

Release builds cover [all platforms](PLATFORMS.md). Publication requires a clean
checkout, reruns consumer tests, and uploads three verified files:

- `Libmpv.xcframework.zip`
- `Inputs.lock.json` — build inputs
- `Artifacts.lock.json` — download URL and checksum

Private GitHub releases require authenticated downloads.

## Checks and cleanup

```sh
swift test --package-path Build
Build/mpvbuild generate --check
Build/mpvbuild status
Build/mpvbuild clean         # Remove outputs; keep downloaded inputs.
Build/mpvbuild clean --cache # Also remove inputs and installed build tools.
Build/mpvbuild --help
```

Cache: `.build/mpvbuild`; existing `.build/native` stores are reused.
