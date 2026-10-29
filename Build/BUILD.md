# Building MPVUI

Build native libraries for Apple platforms or [Android](#android-libraries), then select or package the result for app development. See [Architecture](../Documentation/ARCHITECTURE.md#build-and-distribution) for the two build pipelines.

- `make build` applies [patches](PATCHES.md) and packages mpv, FFmpeg, and their dependencies as `Libmpv.xcframework.zip`. SwiftPM imports it as `Libmpv-GPL`.
- [Inputs.lock.json](Inputs.lock.json) pins build inputs and tool versions.
- [PLATFORMS.md](PLATFORMS.md) lists native targets.

## Commands

Run `make COMMAND`. The commands follow the development workflow:

| Command     | Purpose                                                           |
| ----------- | ----------------------------------------------------------------- |
| `setup`     | Check requirements, install build tools, and generate test media |
| `build`     | Build native libraries and check that they import and link        |
| `select`    | Choose the native artifact that `Package.swift` uses              |
| `test`      | Run tests. `SUITE` chooses which                                  |
| `release`   | Create, check, and publish artifacts. `STEP` chooses the step     |
| `benchmark` | Measure performance. `STEP` chooses the step                      |
| `update`    | Update native dependency pins                                     |
| `clean`     | Remove build outputs and test results                             |
| `format`    | Format sources                                                    |

Options choose what runs. `PLATFORM=android` targets Android, and `PROFILE=release` builds every Apple slice. `ARGS` passes options to the selected tool, and `ARGS=--help` lists them. Run `make help` to see every command, suite, step, and option. `make -C Build` accepts the same commands.

Commands stream tool output and save logs and results in `.build/validation`. Add `JSON=1` to print one JSON result per step instead, following [result.schema.json](result.schema.json). The result's `artifacts` field lists full logs and reports. Name several commands to run them in order, for example `make build test`. Make stops at the first failure.

## Apple libraries

```sh
make setup
make build
make select
```

`make setup` checks requirements and installs build tools. The `dev` profile builds macOS for the host architecture. Pass build options through `ARGS` for other targets:

- iOS: `make build ARGS='--slices ios,isimulator,macos --arch arm64'`
- tvOS: `make build ARGS='--slices tvos,tvsimulator,macos --arch arm64'`

Each build becomes the latest candidate after its native checks pass. Package tests use the artifact selected in `Package.swift`, so `make select` points the manifest at the latest candidate. Run `make select ARGS=--remote` before committing to restore the published artifact.

## Apple release

```sh
make release ARGS='--tag X.Y.Z'
```

Replace `X.Y.Z` with the intended version. This builds every native target, runs consumer tests, and creates a local publication bundle. `artifacts.publicationBundle` identifies the bundle. Pass `--offline` or `--fresh` through `ARGS` to use cached inputs or rebuild outputs. To validate an existing complete build without recompiling it, add `--candidate /path/to/candidate`.

Publication uses explicit steps. `STEP=publish` uploads a bundle, `STEP=adopt` records a published release in the lock files, and `STEP=package` creates the package release for a tagged checkout. `STEP=check` confirms that the committed manifest matches the adopted release.

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
make build PLATFORM=android
```

The build compiles both supported architectures, which packaging requires. It locates the matching Swift compiler automatically. Set `MPVUI_SWIFT` to its executable if needed. It installs the pinned Rust toolchain and cargo-c, and keeps native outputs in `.build/android`.

After changing shared core or bridge sources, pass `ARGS=--package-only` to rebuild them against existing native dependencies. Use `ARGS=--clean` to rebuild native compilation directories.

### Local repository

`make release PLATFORM=android` creates a local Maven bundle, AAR, corresponding sources, and checksums. The version comes from `Android/gradle.properties`, or from `ARGS='--version X.Y.Z'`. The JSON result identifies `artifacts.androidPublicationBundle`. This command does not upload files.

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

Run `make test PLATFORM=android SUITE=consumer` to build independent debug and optimized release applications from the bundle.

## Dependency updates

`make update ARGS=--all` moves every native dependency to its latest stable release and checks that both platforms' patches still apply. `ARGS='--component mpv --ref REF'` pins one source to a specific tag or branch. A weekly workflow opens a pull request with the same update.

## Formatting

```sh
brew bundle
make format
make format CHECK=1
```

Hooks run SwiftFormat, Ruff, clang-format, shfmt, and Prettier for their supported files.

## Cleanup

```sh
make clean
make clean ARGS=--cache
```

`make clean` removes build outputs and test results in `.build`. It keeps downloaded inputs, build tools, test media, and benchmark reports. `--cache` removes the downloads, tools, and test media too.
