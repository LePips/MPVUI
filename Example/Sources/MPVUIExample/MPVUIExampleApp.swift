import SwiftUI

// SKIP @bridge
public struct MPVUIExampleRootView: View {

    // SKIP @bridge
    public init() {}
}

public extension MPVUIExampleRootView {

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        if ProcessInfo.processInfo.arguments.contains("--playback-regression") {
            PlaybackRegressionView()
        } else if ProcessInfo.processInfo.arguments.contains("--playback-benchmark") {
            PlaybackBenchmarkView()
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }
}
