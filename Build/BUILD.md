# Building MPVUI

- `Build/mpvbuild` applies [patches](PATCHES.md) and packages mpv, FFmpeg, and their dependencies as `Libmpv.xcframework.zip`.
- SwiftPM imports the framework as `Libmpv-GPL`.
- [Inputs.lock.json](Inputs.lock.json) pins sources, patches, dependencies, and toolchain versions
-  [PLATFORMS.md](PLATFORMS.md) lists native build targets
- `Package.swift` defines the Swift wrapper's supported platforms

## Local build

Run from the repository root. Requires Python 3.10+, the pinned Xcode, shaderc (`glslc`), and NASM. The doctor checks their versions and bootstraps build tools.

```sh
Build/mpvbuild doctor --bootstrap
Build/mpvbuild build --profile dev
Build/mpvbuild use local --artifact /path/to/candidate
```

Use the candidate path printed by the build. The development profile builds macOS for the host architecture. Add `--slices ios,isimulator,macos --arch arm64` for iOS development, or `--slices tvos,tvsimulator,macos --arch arm64` for tvOS. Refresh package resolution in Xcode after changing the selected artifact.

## Release candidate

```sh
Build/mpvbuild release candidate --tag X.Y.Z
```

Replace `X.Y.Z` with the intended version. This builds every native target, runs consumer tests, and creates a local publication bundle. Publishing is a separate operation. `--offline` uses cached inputs; `--fresh` rebuilds outputs.

To use the artifact recorded in `Artifacts.lock.json`:

```sh
Build/mpvbuild use remote
Build/mpvbuild generate --check
```

The generation check requires a remote artifact selection.

## Cleanup

Build outputs live in `.build/mpvbuild`.

```sh
Build/mpvbuild clean         # Keep downloaded inputs and build tools.
Build/mpvbuild clean --cache # Remove inputs and build tools too.
Build/mpvbuild --help
```
