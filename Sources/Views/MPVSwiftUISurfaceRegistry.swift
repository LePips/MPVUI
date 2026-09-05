import Dispatch

/// Tracks weak SwiftUI playback surfaces and restores the most recent live one.
@MainActor
final class MPVSwiftUISurfaceRegistry<Surface: AnyObject> {
    private final class Entry {
        let surface: WeakBox<Surface>
        var isInWindow = false

        init(surface: Surface) {
            self.surface = WeakBox(surface)
        }
    }

    private let isAttachedToWindow: (Surface) -> Bool
    private let activate: (Surface) -> Void
    private var surfacesByPlayer: [ObjectIdentifier: [Entry]] = [:]

    init(
        isAttachedToWindow: @escaping (Surface) -> Bool,
        activate: @escaping (Surface) -> Void
    ) {
        self.isAttachedToWindow = isAttachedToWindow
        self.activate = activate
    }

    func register(_ surface: Surface, for player: MPVPlayer) {
        let key = ObjectIdentifier(player)
        var surfaces = liveSurfaces(for: key)
        surfaces.removeAll { $0.surface.value === surface }
        surfaces.append(Entry(surface: surface))
        surfacesByPlayer[key] = surfaces
    }

    func unregister(_ surface: Surface, for player: MPVPlayer) {
        let key = ObjectIdentifier(player)
        var surfaces = liveSurfaces(for: key)
        surfaces.removeAll { $0.surface.value === surface }

        if surfaces.isEmpty {
            surfacesByPlayer.removeValue(forKey: key)
        } else {
            surfacesByPlayer[key] = surfaces
        }
    }

    func surfaceDidMoveToWindow(
        _ surface: Surface,
        player: MPVPlayer,
        isInWindow: Bool,
        shouldRestorePreviousSurface: Bool
    ) {
        let key = ObjectIdentifier(player)
        var surfaces = liveSurfaces(for: key)
        guard let entry = surfaces.first(where: { $0.surface.value === surface }) else {
            return
        }

        entry.isInWindow = isInWindow

        if isInWindow {
            surfaces.removeAll { $0 === entry }
            surfaces.append(entry)
        }
        surfacesByPlayer[key] = surfaces

        if !isInWindow, shouldRestorePreviousSurface {
            scheduleRestoringMostRecentSurface(for: player)
        }
    }

    func activateMostRecentSurface(for player: MPVPlayer) {
        // A native surface may have claimed the player after restoration was
        // queued. Never let an older SwiftUI surface steal that newer owner.
        guard !player.hasActiveRenderSurface else { return }

        let key = ObjectIdentifier(player)
        let surfaces = liveSurfaces(for: key)
        guard !surfaces.isEmpty else {
            surfacesByPlayer.removeValue(forKey: key)
            return
        }
        surfacesByPlayer[key] = surfaces

        guard let entry = surfaces.reversed().first(where: {
            guard let surface = $0.surface.value else { return false }
            return $0.isInWindow && isAttachedToWindow(surface)
        }),
            let surface = entry.surface.value
        else {
            return
        }

        var reorderedSurfaces = surfaces
        reorderedSurfaces.removeAll { $0 === entry }
        reorderedSurfaces.append(entry)
        surfacesByPlayer[key] = reorderedSurfaces
        activate(surface)
    }

    private func liveSurfaces(for key: ObjectIdentifier) -> [Entry] {
        (surfacesByPlayer[key] ?? []).filter { $0.surface.value != nil }
    }

    private func scheduleRestoringMostRecentSurface(for player: MPVPlayer) {
        DispatchQueue.main.async { [weak self, weak player] in
            guard let self, let player else { return }
            self.activateMostRecentSurface(for: player)
        }
    }
}
