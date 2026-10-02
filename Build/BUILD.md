# Building MPVUI

- `make build` applies [patches](PATCHES.md) and packages mpv, FFmpeg, and their dependencies as `Libmpv.xcframework.zip`. SwiftPM imports it as `Libmpv-GPL`.
- [Inputs.lock.json](Inputs.lock.json) pins build inputs and tool versions.
- [PLATFORMS.md](PLATFORMS.md) lists native targets.

Use `make help` to discover targets and `make help TARGET=build` for native options. `make -C Build` uses the same definitions.

Build, test, and benchmark targets emit one JSON result per step, following [result.schema.json](result.schema.json). The `artifacts` field lists full logs and report paths. Multiple steps produce JSON Lines. `make verify` builds and then tests, stopping on failure. Benchmarks run only when requested. Use `BUILD_ARGS`, `TEST_ARGS`, or `BENCHMARK_ARGS` to pass options to a specific phase. The native build defaults to `PROFILE=dev`. Use `PROFILE=release` for release builds.

## Local build

```sh
make doctor # Install tools, check versions
make build
make use-local ARGS='--artifact /path/to/candidate'
```

Use `artifacts.nativeCandidate` from the JSON build result. The `dev` profile builds macOS for the host architecture. Pass native options through `ARGS` for other targets:

- iOS: `make build ARGS='--slices ios,isimulator,macos --arch arm64'`
- tvOS: `make build ARGS='--slices tvos,tvsimulator,macos --arch arm64'`

Artifact selection updates `Package.swift`. Refresh package resolution in Xcode afterward. Run `make use-remote` before committing the manifest.

Package tests, including `make verify`, use the native artifact selected in `Package.swift`. Building a new candidate does not change that selection. Use `make use-local` to test the wrapper against the candidate, or `make test-artifact ARGS='--candidate /path/to/candidate'` to run its consumer checks.

## Release candidate

```sh
make release-candidate ARGS='--tag X.Y.Z'
```

Replace `X.Y.Z` with the intended version. This builds every native target, runs consumer tests, and creates a local publication bundle. Publishing is a separate operation. `artifacts.publicationBundle` identifies the local bundle. Pass `--offline` or `--fresh` through `ARGS` to use cached inputs or rebuild outputs.

To use the artifact recorded in `Artifacts.lock.json`:

```sh
make use-remote
make generate ARGS='--check'
```

## Formatting

Install `pre-commit`, then format or check project source files from the repository root:

```sh
brew install pre-commit
make format
make format-check
```

Hooks format project sources and configuration files, excluding generated assets and checksum-locked patches.

## Cleanup

Build outputs live in `.build/mpvbuild`.

```sh
make clean                # Keep downloaded inputs and build tools.
make clean ARGS='--cache' # Remove inputs and build tools too.
make help
```
