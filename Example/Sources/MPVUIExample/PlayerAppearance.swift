import SwiftUI

// Platform presentation choices stay outside the shared playback controls.
extension View {

    func playerControlsVisible(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }

    @ViewBuilder
    func playerSurfaceHitArea() -> some View {
        #if os(Android)
        // Compose buttons already hit-test their full layout bounds.
        self
        #else
        self
            .contentShape(Rectangle())
        #endif
    }

    @ViewBuilder
    func playerMediaTitle() -> some View {
        #if os(Android)
        self
        #else
        self
            .truncationMode(.middle)
        #endif
    }

    @ViewBuilder
    func playerMenu() -> some View {
        #if os(Android)
        self
        #else
        self
            .menuIndicator(.hidden)
            .menuOrder(.fixed)
        #endif
    }
}

/// One effect on the whole view produces a continuous trailing toolbar capsule.
extension View {

    @ViewBuilder
    func playerCapsule() -> some View {
        #if os(Android)
        self
            .background(.black.opacity(0.6), in: Capsule())
            .overlay(Capsule()
                .stroke(.white.opacity(0.2), lineWidth: 1))
        #else
        self
            .glassEffect(.regular.interactive(), in: .capsule)
        #endif
    }
}

struct PlayerAudioArtwork: View {

    var body: some View {
        #if os(Android)
        ComposeView { PlayerGlyphComposer(name: "music.note") }
            .frame(width: 96, height: 96)
            .opacity(0.6)
        #else
        Image(systemName: "music.note")
            .font(.system(size: 96, weight: .light))
            .foregroundStyle(.secondary)
        #endif
    }
}

struct PlayerGlyph: View {

    let name: String
    let size: Double

    var body: some View {
        #if os(Android)
        ComposeView { PlayerGlyphComposer(name: name) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        #else
        Image(systemName: name)
            .font(.system(size: size, weight: .medium))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        #endif
    }
}

#if SKIP
struct PlayerGlyphComposer {

    let name: String
}

extension PlayerGlyphComposer: ContentComposer {

    @Composable
    func Compose(context: ComposeContext) {
        PlayerChromeIcon(name: name, modifier: context.modifier)
    }
}
#endif
