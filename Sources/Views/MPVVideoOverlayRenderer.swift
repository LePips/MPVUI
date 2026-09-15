import Combine
import SwiftUI

/// Rasterizes only the overlay. mpv continues to decode and schedule video.
/// One submission may be in flight; intermediate invalidations are coalesced.
@MainActor
final class MPVVideoOverlayRenderer {
    private let renderer: ImageRenderer<AnyView>
    private var content: AnyView
    private let submit: @MainActor (MPVVideoOverlayBitmap?) async -> Bool
    private let availabilityChanged: @MainActor (Bool) -> Void
    private var observation: AnyCancellable?
    private var renderTask: Task<Void, Never>?
    private var isDirty = false
    private var isInvalidated = false
    private var size: CGSize = .zero
    private var rasterScale: CGFloat = 1

    init(
        content: AnyView,
        submit: @escaping @MainActor (MPVVideoOverlayBitmap?) async -> Bool,
        availabilityChanged: @escaping @MainActor (Bool) -> Void
    ) {
        renderer = ImageRenderer(content: content)
        renderer.isOpaque = false
        self.content = content
        self.submit = submit
        self.availabilityChanged = availabilityChanged
        observation = renderer.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.setNeedsRender() }
        }
    }

    func updateContent(_ content: AnyView) {
        self.content = content
        updateRendererContent()
        setNeedsRender()
    }

    func updateSize(_ proposedSize: CGSize, displayScale: CGFloat = 2, rasterSize: CGSize? = nil) {
        guard proposedSize.width.isFinite, proposedSize.height.isFinite,
              proposedSize.width > 0, proposedSize.height > 0,
              displayScale.isFinite, displayScale > 0 else { return }
        // Supersample the overlay for cleaner text after native composition and
        // PiP downscaling. Match the bitmap's 2048-pixel allocation limit.
        let supersampling: CGFloat = 2
        var scale = min(displayScale * supersampling, 2048 / max(proposedSize.width, proposedSize.height))
        if let rasterSize, rasterSize.width.isFinite, rasterSize.height.isFinite,
           rasterSize.width > 0, rasterSize.height > 0
        {
            scale = min(scale, supersampling * max(
                rasterSize.width / proposedSize.width,
                rasterSize.height / proposedSize.height
            ))
        }
        guard proposedSize != size || displayScale != renderer.scale || scale != rasterScale else { return }
        if proposedSize != size {
            size = proposedSize
            renderer.proposedSize = ProposedViewSize(proposedSize)
            updateRendererContent()
        }
        // Keep SwiftUI's layout pixel grid stable as PiP resolution changes.
        renderer.scale = displayScale
        rasterScale = scale
        setNeedsRender()
    }

    private func updateRendererContent() {
        // A proposal alone lets intrinsic-size content shrink the bitmap, which
        // mpv would then stretch across the entire video frame.
        renderer.content = AnyView(content.frame(width: size.width, height: size.height))
    }

    func invalidate() {
        isInvalidated = true
        observation = nil
        renderTask?.cancel()
        renderTask = nil
    }

    isolated deinit { invalidate() }

    private func setNeedsRender() {
        guard !isInvalidated, size.width > 0, size.height > 0 else { return }
        isDirty = true
        guard renderTask == nil else { return }
        renderTask = Task { @MainActor [weak self] in
            // Deferring lets SwiftUI settle the change that invalidated the image.
            await Task.yield()
            while let self, !self.isInvalidated, !Task.isCancelled, self.isDirty {
                self.isDirty = false
                // Draw directly into CPU-owned storage. This does not depend
                // on a visible UIKit view or a foreground window snapshot.
                var bitmap: MPVVideoOverlayBitmap?
                self.renderer.render(rasterizationScale: self.rasterScale) { size, draw in
                    bitmap = MPVVideoOverlayBitmap(size: size, scale: self.rasterScale, draw: draw)
                }
                let accepted = await self.submit(bitmap)
                guard !self.isInvalidated, !Task.isCancelled else { return }
                self.availabilityChanged(bitmap != nil && accepted)
                // Bound rapidly changing overlays to 30 updates/sec. Video is
                // still scheduled independently at its original frame rate.
                do { try await Task.sleep(for: .milliseconds(34)) } catch { return }
            }
            self?.renderTask = nil
        }
    }
}
