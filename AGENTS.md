- [README.md](README.md): project overview and basic SwiftUI usage.
- [Build/BUILD.md](Build/BUILD.md): build requirements, local development, release candidates, and cleanup.
- [TESTING.md](TESTING.md): test organization, commands, media fixtures, and native and system checks.
- [TEST_MEDIA.md](TEST_MEDIA.md): generated test media, adding fixtures, and coverage gaps.
- [Build/PATCHES.md](Build/PATCHES.md): mpv and FFmpeg patches and their purposes.
- [Build/RENDERING.md](Build/RENDERING.md): video outputs, HDR, picture in picture, subtitles, and fonts.
- [Build/PLATFORMS.md](Build/PLATFORMS.md): generated native build targets, architectures, minimum OS versions, and SDKs.
- [Build/Patches/AVFOUNDATION_CREDITS.md](Build/Patches/AVFOUNDATION_CREDITS.md): sources and licenses for imported AVFoundation changes.

- Do not create pull requests against the GitHub repository unless explicitly requested.
- Keep Markdown documentation focused on important build, architecture, and project guidance. Do not document every feature.
- Do not add or update Markdown documentation for reports, audits, results, or otherwise.
- Do not add transitional, migration, or temporary implementations. Keep all changes current.

- Document new public APIs with clear, brief Swift documentation comments.
- Run SwiftFormat after completing the work.

- Use `make TARGET` from the repository root for builds, tests, and requested benchmarks. See `make help` for targets and options.
- Read completed JSON summaries first. Open logs only for unresolved failures, warnings, or missing evidence.
- Wait for completion instead of repeatedly polling status or tailing logs.
- Do not edit documentation or READMEs directly. Stage proposed revisions in `sandbox` and obtain explicit confirmation before applying them.
