#if !os(Android)
import MediaAccessibilityKit
import MPVUI
import SwiftUI

/// Uses the shared layout with the user's system caption style.
@MainActor
struct TextSubtitleOverlay: View {

    let snapshot: TextSubtitleSnapshot
    let videoSize: CGSize?

    var body: some View {
        MPVTextSubtitleOverlay(snapshot: snapshot, videoSize: videoSize) { region in
            CaptionText(region.text, baseSize: 21)
        }
    }
}
#endif
