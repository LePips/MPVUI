import SwiftUI

#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit

/// Owned by the render surface, preserving identity and state across reparenting.
@MainActor
final class MPVVideoOverlayHostingView: NSHostingView<AnyView> {
    init(content: AnyView) {
        super.init(rootView: content)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init(rootView: AnyView) {
        fatalError()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func setContent(_ content: AnyView) {
        rootView = content
    }
}
#elseif canImport(UIKit)
import UIKit

@MainActor
final class MPVVideoOverlayHostingView: UIView {
    private let controller: UIHostingController<AnyView>
    private(set) var layoutSize: CGSize = .zero

    init(content: AnyView) {
        controller = UIHostingController(rootView: content)
        super.init(frame: .zero)
        backgroundColor = .clear
        controller.view.backgroundColor = .clear
        controller.view.frame = bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(controller.view)
        setContent(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func setContent(_ content: AnyView) {
        controller.rootView = AnyView(content.onGeometryChange(for: CGSize.self) { geometry in
            geometry.size
        } action: { [weak self] size in
            self?.layoutSize = size
        })
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        var ancestor: UIResponder? = superview
        while let candidate = ancestor, !(candidate is UIViewController) {
            ancestor = candidate.next
        }
        let parent = window == nil ? nil : ancestor as? UIViewController
        guard controller.parent !== parent else { return }
        controller.willMove(toParent: nil)
        controller.removeFromParent()
        if let parent {
            parent.addChild(controller)
            controller.didMove(toParent: parent)
        }
    }
}
#endif
