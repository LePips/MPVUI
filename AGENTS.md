- [README.md](README.md): Project overview and basic SwiftUI usage.
- [Build/BUILD.md](Build/BUILD.md): Build requirements, local development, release candidates, and cleanup.
- [TESTING.md](TESTING.md): Test organization, commands, media fixtures, and native and system checks.
- [Build/PATCHES.md](Build/PATCHES.md): mpv and FFmpeg patches and their purposes.
- [Build/RENDERING.md](Build/RENDERING.md): Video outputs, HDR, picture in picture, subtitles, and fonts.
- [Build/PLATFORMS.md](Build/PLATFORMS.md): Generated native build targets, architectures, minimum OS versions, and SDKs.
- [Build/Patches/AVFOUNDATION_CREDITS.md](Build/Patches/AVFOUNDATION_CREDITS.md): Sources and licenses for imported AVFoundation changes.

- Do not create PRs against the GitHub repo unless explicitly requested.
- Do not add or update markdown documentation for every single feature, only most important high level notes for building, architecture, and other.
- Do not add or update markdown documentation for reports, audits, results, or otherwise.
- No transitory, migration, or temporary changes or implementations. Everything is to remain current.

- New public APIs should have clear and brief documentation as correct Swift comments.
- Run swiftformat after complete with work.
