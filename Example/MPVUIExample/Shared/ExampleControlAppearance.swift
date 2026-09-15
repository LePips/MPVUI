import SwiftUI

extension View {
    func exampleGlassButton() -> some View {
        buttonStyle(.glass)
            .buttonBorderShape(.capsule)
    }
}

/// Keeps each group of controls in one glass rendering pass.
struct ExampleGlassControls<Content: View>: View {
    @ViewBuilder
    var content: Content

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            content
        }
    }
}
