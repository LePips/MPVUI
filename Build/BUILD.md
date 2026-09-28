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

## Dependency update PRs

GitHub Actions checks for stable native releases every Monday at 08:17 UTC. Run
**Native dependency updates** from the Actions tab to check immediately. Each
component has one reusable draft PR branch; nothing merges or publishes automatically.

- FFmpeg and mpv follow stable release tags. The updater resolves the tag to an
  immutable commit and applies the ordered Apple patches. When
  `Build/Android/Native.lock.json` exists, the updater also checks its patches
  independently and changes both platform locks together. A patch conflict fails that component's
  job without changing its lockfiles; other components continue.
- Every prebuilt SDK in `Inputs.lock.json` follows its mpvkit release repository.
  Libraries shipped together (such as libass and its font libraries) update in one
  PR. All SDK and runtime archives must exist; the updater downloads and hashes each
  archive and compares GitHub's asset digest when available. Drafts, prereleases,
  and development tags are excluded. Numeric release tags and the existing `-fix`
  and numeric packaging suffixes are supported.
- Dependabot checks GitHub Actions weekly, grouped in one PR. Add a Gradle entry
  for `/Android` in `.github/dependabot.yml` when the Android project lands on `main`.

The native workflow uses `GITHUB_TOKEN`, with write access limited to its update
jobs. Repository **Settings → Actions → General → Workflow permissions → Allow
GitHub Actions to create and approve pull requests** must be enabled. No personal
token or external service is required. GitHub may require **Approve workflows to
run** on bot-created PRs; the updater also verifies each candidate before opening
its PR. See [GitHub's token behavior](https://docs.github.com/en/actions/concepts/security/github_token).

Preview or validate locally with Python 3.10+ and Git (no Xcode needed):

```sh
python3 Build/update_dependencies.py --list
python3 Build/update_dependencies.py --component ffmpeg --dry-run
python3 Build/update_dependencies.py --component sdk-mpvkit-libass-build --dry-run
python3 Build/update_dependencies.py --validate
python3 -m unittest discover -s Build/Tests -p 'test_update_dependencies.py'
```

Without `--dry-run`, a component update writes the affected lockfiles. Set
`GH_TOKEN` for authenticated GitHub API requests when checking SDK releases locally.

Patch application and checksum checks do not prove build or playback compatibility.
Before merging a native update, build a complete Apple release candidate and the
affected Android native libraries when present, then run their consumer/playback tests. Updating
source locks does not replace published binaries: release and adoption remain
separate steps. The updater leaves `Artifacts.lock.json` and `Package.swift` alone.

Recipe revisions, Xcode/SDK/NDK and build-tool pins, and Android-only native
dependencies remain manual because their versions are coupled to the build recipes.

## Cleanup

Build outputs live in `.build/mpvbuild`.

```sh
Build/mpvbuild clean         # Keep downloaded inputs and build tools.
Build/mpvbuild clean --cache # Remove inputs and build tools too.
Build/mpvbuild --help
```
