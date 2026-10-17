import MPVUIExample
import SwiftUI

@main
struct MPVUIExampleApp {}

extension MPVUIExampleApp: App {

    var body: some Scene {
        WindowGroup {
            MPVUIExampleRootView()
                #if os(macOS)
                    .frame(minWidth: 640, minHeight: 360)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 960, height: 540)
        #endif
    }
}
