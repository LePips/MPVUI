# Building MPVUI

Build native libraries for Apple platforms or [Android](#android-libraries), then select or package the result for app development. See [Architecture](../Documentation/ARCHITECTURE.md#build-and-distribution) for the two build pipelines.

- `just build` applies [patches](PATCHES.md) and packages mpv, FFmpeg, and their dependencies as `Libmpv.xcframework.zip`. SwiftPM imports it as `Libmpv-GPL`.
- [Inputs.lock.json](Inputs.lock.json) pins build inputs and tool versions.
- [PLATFORMS.md](PLATFORMS.md) lists native targets.

## Commands

Install the developer tools with `brew bundle`, then run `just COMMAND`. Just 1.55 or newer is required. The commands follow the development workflow:

| Command     | Purpose                                                       |
| ----------- | ------------------------------------------------------------- |
| `setup`     | Check requirements, install build tools, and prepare test media |
| `build`     | Build native libraries and check that they import and link     |
| `select`    | Choose the native artifact that `Package.swift` uses           |
| `test`      | Run tests. `--suite` chooses which                             |
| `release`   | Create, check, and publish artifacts. `--step` chooses the step |
| `benchmark` | Measure performance. `--step` chooses the step                  |
| `update`    | Update native dependency pins                                 |
| `clean`     | Remove build outputs and test results                          |
| `format`    | Format sources                                                |

Named flags choose what runs. `--platform android` targets Android, and `--profile release` builds every Apple slice. Arguments after `--` go to the selected tool. For example, `just build -- --help` lists native build options. Run `just help` for all suites and steps, `just --list` for recipes, or `just --usage COMMAND` for a command's flags. The root `justfile` is found from any project subdirectory. Use `just --set python /path/to/python3 COMMAND` to select a Python executable.

Commands stream tool output and save logs and results in `.build/validation`. Add `--json` before `--` to print one JSON result per step instead, following [result.schema.json](result.schema.json). The result's `artifacts` field lists full logs and reports. Chain commands with `&&` to run them in order and stop on failure, for example `just build && just test`. Each recipe owns its trailing arguments, so `just build test` passes `test` to the build tool.

The Python router runs the existing Apple, Android, test, and release tools. Native compilation and caching remain in those tools. Upstream dependencies still use Make where their build systems require it.

## Apple libraries

```sh
just setup
just build
just select
```

`just setup` checks requirements and installs native build tools. The `dev` profile builds macOS for the host architecture. Pass build options after `--` for other targets:

- iOS: `just build -- --slices ios,isimulator,macos --arch arm64`
- tvOS: `just build -- --slices tvos,tvsimulator,macos --arch arm64`

Each build becomes the latest candidate after its native checks pass. Package tests use the artifact selected in `Package.swift`, so `just select` points the manifest at the latest candidate. Run `just select -- --remote` before committing to restore the published artifact.

## Apple release

```sh
just release -- --tag X.Y.Z
```

Replace `X.Y.Z` with the intended version. This builds every native target, runs consumer tests, and creates a local publication bundle. `artifacts.publicationBundle` identifies the bundle. Pass `--offline` or `--fresh` after `--` to use cached inputs or rebuild outputs. To validate an existing complete build without recompiling it, add `--candidate /path/to/candidate`.

Publication uses explicit steps. `--step publish` uploads a bundle, `--step adopt` records a published release in the lock files, and `--step package` creates the package release for a tagged checkout. `--step check` confirms that the committed manifest matches the adopted release.

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
just build --platform android
```

The build compiles both supported architectures, which packaging requires. It locates the matching Swift compiler automatically. Set `MPVUI_SWIFT` to its executable if needed. It installs the pinned Rust toolchain and cargo-c, and keeps native outputs in `.build/android`.

After changing shared core or bridge sources, pass `-- --package-only` to rebuild them against existing native dependencies. Use `-- --clean` to rebuild native compilation directories.

### Local repository

`just release --platform android` creates a local Maven bundle, AAR, corresponding sources, and checksums. The version comes from `Android/gradle.properties`, or from `-- --version X.Y.Z`. The JSON result identifies `artifacts.androidPublicationBundle`. This command does not upload files.

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

Run `just test --platform android --suite consumer` to build independent debug and optimized release applications from the bundle.

## Dependency updates

`just update -- --all` moves every native dependency to its latest stable release and checks that both platforms' patches still apply. `-- --component mpv --ref REF` pins one source to a specific tag or branch. A weekly workflow opens a pull request with the same update.

## Formatting

```sh
brew bundle
just format
just format --check
```

Hooks run SwiftFormat, Ruff, clang-format, shfmt, and Prettier for their supported files. Just formats the root `justfile`. `--check` uses the hooks' check mode without rewriting files.

## Cleanup

```sh
just clean
just clean -- --cache
```

`just clean` removes build outputs and test results in `.build`. It keeps downloaded inputs, build tools, test media, and benchmark reports. `--cache` removes the downloads, tools, and test media too.
