import SwiftUI

@main
struct MPVUIExampleApp: App {
    var body: some Scene {
        WindowGroup {
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
                #if os(macOS)
                    .frame(minWidth: 800, minHeight: 450)
                #endif
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 720)
            .windowStyle(.hiddenTitleBar)
        #endif
    }
}
