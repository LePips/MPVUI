import SwiftUI

@main
struct MPVUIExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
            #if os(macOS)
                .frame(minWidth: 800, minHeight: 450)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 720)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}
