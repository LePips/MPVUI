import Foundation

#if os(tvOS)
import AVFoundation
import AVKit
import UIKit
#endif

/// Selects an endpoint only where a platform implements content-driven display
/// matching. Native sample-buffer HDR presentation is independent of this API.
@MainActor
enum MPVPlatformDisplayMatchingTarget {
    static func make(for window: PlatformWindow?) -> (any MPVDisplayMatchingTarget)? {
        #if os(tvOS)
        return window.map { MPVTVDisplayMatchingTarget(manager: $0.avDisplayManager) }
        #else
        // iOS exposes presentation cadence hints, not AVDisplayManager. macOS
        // mode changes require a separate desktop-wide selection/restore policy.
        return nil
        #endif
    }
}

#if os(tvOS)
/// Kept at the AVKit boundary so adapter tests need not switch a physical TV.
@MainActor
protocol MPVAVDisplayManaging: AnyObject {
    var preferredDisplayCriteria: AVDisplayCriteria? { get set }
    var isDisplayCriteriaMatchingEnabled: Bool { get }
    var isDisplayModeSwitchInProgress: Bool { get }
}

extension AVDisplayManager: MPVAVDisplayManaging {}

@MainActor
final class MPVTVDisplayMatchingTarget: MPVDisplayMatchingTarget {
    private let manager: any MPVAVDisplayManaging

    init(manager: any MPVAVDisplayManaging) {
        self.manager = manager
    }

    var identity: ObjectIdentifier {
        ObjectIdentifier(manager)
    }

    var isMatchingEnabled: Bool {
        manager.isDisplayCriteriaMatchingEnabled
    }

    var isModeSwitchInProgress: Bool {
        manager.isDisplayModeSwitchInProgress
    }

    func apply(_ content: MPVDisplayMatchingContent?) -> Bool {
        guard let content else {
            manager.preferredDisplayCriteria = nil
            return true
        }
        guard let format = content.makeFormatDescription() else { return false }
        manager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: content.refreshRate, formatDescription: format
        )
        return true
    }

    func observeChanges(_ onChange: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let observations = [
            NSNotification.Name.AVDisplayManagerModeSwitchStart,
            NSNotification.Name.AVDisplayManagerModeSwitchEnd,
            NSNotification.Name.AVDisplayManagerModeSwitchSettingsChanged,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            }
        }
        return {
            for observation in observations {
                NotificationCenter.default.removeObserver(observation)
            }
        }
    }
}
#endif
