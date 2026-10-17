# Building MPVUI

Build native libraries for Apple platforms or [Android](#android-libraries), then select or package the result for app development. See [Architecture](../Documentation/ARCHITECTURE.md#build-and-distribution) for the two build pipelines.

- `make build` applies [patches](PATCHES.md) and packages mpv, FFmpeg, and their dependencies as `Libmpv.xcframework.zip`. SwiftPM imports it as `Libmpv-GPL`.
- [Inputs.lock.json](Inputs.lock.json) pins build inputs and tool versions.
- [PLATFORMS.md](PLATFORMS.md) lists native targets.

Run `make TARGET`. Use `make help` to discover targets and `make help TARGET=build` for native options. Pass options through `ARGS`. `make -C Build` uses the same definitions.

Targets stream tool output and save logs and results in `.build/validation`. Add `JSON=1`, for example `make format JSON=1`, to print one JSON result per step instead, following [result.schema.json](result.schema.json). Multiple steps produce JSON Lines. The result's `artifacts` field lists full logs and reports.

`make verify` builds Apple libraries and runs package tests, stopping on failure. Use `BUILD_ARGS`, `TEST_ARGS`, or `BENCHMARK_ARGS` for options that apply to one phase. The native build defaults to `PROFILE=dev`. Use `PROFILE=release` for release builds.

## Apple libraries

```sh
make doctor
make build
make use-local ARGS='--artifact /path/to/candidate'
```

`make doctor` checks requirements and installs build tools. Use `artifacts.nativeCandidate` from the build result when selecting the artifact. The `dev` profile builds macOS for the host architecture. Pass native options through `ARGS` for other targets:

- iOS: `make build ARGS='--slices ios,isimulator,macos --arch arm64'`
- tvOS: `make build ARGS='--slices tvos,tvsimulator,macos --arch arm64'`

Artifact selection updates `Package.swift`. Run `make use-remote` before committing the manifest to ensure not pointing to a local artifact.

Package tests, including `make verify`, use the native artifact selected in `Package.swift`. Building a new candidate doesn't change that selection. Use `make use-local` to test the wrapper against the candidate, or `make test-artifact ARGS='--candidate /path/to/candidate'` to run its consumer checks.

## Apple release candidate

```sh
make release-candidate ARGS='--tag X.Y.Z'
```

Replace `X.Y.Z` with the intended version. This builds every native target, runs consumer tests, and creates a local publication bundle. `artifacts.publicationBundle` identifies the local bundle. Pass `--offline` or `--fresh` through `ARGS` to use cached inputs or rebuild outputs.

To validate an existing complete native build, add `--candidate /path/to/candidate`. The command checks its inputs and version, reruns consumer tests, and bundles the tested bytes without repeating native compilation.

To use the artifact recorded in `Artifacts.lock.json`:

```sh
make use-remote
make generate ARGS='--check'
```

## Android libraries

Install these dependencies before building:

- Java Development Kit (JDK) 17 and Python 3.12+.
- Android SDK platform 36, build tools 36.0.0, and Native Development Kit (NDK) `30.0.16248370`.
- The Swift compiler and its matching Swift SDK as pinned in [Inputs.lock.json](Inputs.lock.json).
- Rust through rustup, a C/C++ host toolchain, and the native tools in [Brewfile](../Brewfile).

```sh
brew bundle
export ANDROID_HOME="$HOME/Library/Android/sdk"
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
make build-android ARGS='--abi arm64-v8a --abi x86_64'
make build-android-package
```

The build locates the matching Swift compiler automatically. Set `MPVUI_SWIFT` to its executable if needed. It installs the pinned Rust toolchain and cargo-c, and keeps native outputs in `.build/android`.

After changing shared core or bridge sources, pass `--package-only` to rebuild them against existing native dependencies. Use `--clean` to rebuild native compilation directories. Android packaging requires both architectures and checks native libraries, runtime dependencies, and source fingerprints.

### Local repository

`make release-android-candidate` creates a local Maven bundle, AAR, corresponding sources, and checksums. The version comes from `Android/gradle.properties`, or from `ARGS='--version X.Y.Z'`. The JSON result identifies `artifacts.androidPublicationBundle`. This command does not upload files.

Extract the Maven ZIP and add its directory to the consuming application's `settings.gradle.kts`:

```kotlin
dependencyResolutionManagement {
    repositories {
        maven { url = uri("/path/to/extracted/repository") }
        google()
        mavenCentral()
    }
}
```

Run `make test-android-consumer` to build independent debug and optimized release applications from the bundle.

## Formatting

```sh
brew bundle
make format
make format-check
```

Hooks run SwiftFormat, Ruff, clang-format, shfmt, and Prettier for their supported files.

## Cleanup

Apple build outputs live in `.build/mpvbuild`.

```sh
make clean
make clean ARGS='--cache'
```

The default cleanup keeps downloaded inputs and build tools. `--cache` removes those too.
