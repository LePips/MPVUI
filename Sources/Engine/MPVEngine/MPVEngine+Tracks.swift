import Dispatch
import Foundation

// Selects and restores media tracks and manages external-track file access.
extension MPVEngine {
    struct ExternalTrack {
        let url: URL
        let type: MPVTrackType
        let select: Bool
        let subtitleRole: MPVSubtitleRole
    }

    func selectTrack(_ id: MPVMediaTrackIdentifier) {
        if id.type == .subtitle {
            selectSubtitle(id, for: .primary)
        } else {
            setProperty(Self.selectionProperty(for: id.type), to: String(id.mpvID))
        }
    }

    func selectSubtitle(_ id: MPVMediaTrackIdentifier?, for role: MPVSubtitleRole = .primary) {
        queue.async { [weak self] in
            self?.selectSubtitleImmediatelyOrDefer(id, for: role)
        }
    }

    private func selectSubtitleImmediatelyOrDefer(
        _ id: MPVMediaTrackIdentifier?,
        for role: MPVSubtitleRole = .primary
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let id {
            // mpv cannot decode the same track in both slots. Explicitly
            // move it, and retain the resulting Off state for recreation.
            let other = role.other.selectionProperty
            let selected = getString(other) ?? desiredProperties[other]
            if selected == String(id.mpvID) {
                setPropertyImmediatelyOrDefer(other, to: "no")
            }
        }
        setPropertyImmediatelyOrDefer(
            role.selectionProperty, to: id.map { String($0.mpvID) } ?? "no"
        )
    }

    func disableTrack(_ type: MPVTrackType) {
        setProperty(Self.selectionProperty(for: type), to: "no")
    }

    func loadExternalTrack(
        _ url: URL,
        type: MPVTrackType,
        select: Bool,
        subtitleRole: MPVSubtitleRole = .primary
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let track = ExternalTrack(url: url, type: type, select: select, subtitleRole: subtitleRole)
            self.startExternalSecurityScopedAccessIfNeeded(for: url)
            if type != .subtitle || !self.externalTracks.contains(where: { $0.url == url && $0.type == type }) {
                self.externalTracks.append(track)
            }

            guard self.isFileLoaded, self.handle != nil else {
                self.pendingExternalTracks.append(track)
                return
            }

            self.loadExternalTrackImmediately(track)
        }
    }

    func setAudioDelay(_ delay: Duration) {
        setProperty("audio-delay", to: Self.format(delay))
    }

    func setSubtitleDelay(_ delay: Duration, for role: MPVSubtitleRole = .primary) {
        setProperty(role.delayProperty, to: Self.format(delay))
    }

    func setSubtitlesVisible(_ visible: Bool, for role: MPVSubtitleRole) {
        setProperty(role.visibilityProperty, to: visible ? "yes" : "no")
    }

    func loadPendingExternalTracks() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isFileLoaded else { return }

        let tracks = pendingExternalTracks
        pendingExternalTracks.removeAll()
        let selections = desiredProperties.filter {
            ["vid", "aid", "sid", "secondary-sid"].contains($0.key)
        }
        for track in tracks {
            loadExternalTrackImmediately(track)
        }

        // Re-adding an external track with its original `select` flag can
        // temporarily change the active track. A renderer rebuild must honor
        // the user's latest embedded/external/off selection captured above.
        // Clear both before restoring a swapped pair; mpv rejects selecting
        // a track that is still occupying the other slot.
        if selections["sid"] != nil, selections["secondary-sid"] != nil {
            _ = setPropertyImmediately("sid", to: "no")
            _ = setPropertyImmediately("secondary-sid", to: "no")
        }
        for name in ["vid", "aid", "sid", "secondary-sid"] {
            guard let value = selections[name] else { continue }
            desiredProperties[name] = value
            let status = setPropertyImmediately(name, to: value)
            if status < 0 {
                publishCommandError(status, context: "Restore \(name)")
            }
        }
    }

    private func loadExternalTrackImmediately(_ track: ExternalTrack) {
        dispatchPrecondition(condition: .onQueue(queue))
        let path = Self.mpvPath(for: track.url)
        // mpv may already have discovered a sidecar beside the video. Reuse it
        // when loading explicitly, including after renderer recreation.
        if track.type == .subtitle,
           let existing = getNode("track-list")?.arrayValue?.first(where: {
               $0.mapValue?["type"]?.stringValue == "sub"
                   && $0.mapValue?["external-filename"]?.stringValue == path
           }),
           let id = Self.parseTracks(.array([existing])).first?.id
        {
            if track.select {
                selectSubtitleImmediatelyOrDefer(id, for: track.subtitleRole)
            }
            return
        }
        let commandName: String =
            switch track.type {
            case .video: "video-add"
            case .audio: "audio-add"
            case .subtitle: "sub-add"
            }

        let previousIDs = track.type == .subtitle
            ? Set(Self.parseTracks(getNode("track-list")).map(\.id)) : []
        let status = runCommand([
            commandName,
            path,
            track.select && track.type != .subtitle ? "select" : "auto",
        ])
        if status < 0 {
            publishCommandError(status, context: "Load external \(track.type.rawValue) track")
        } else if track.type == .subtitle, track.select,
                  let added = Self.parseTracks(getNode("track-list")).first(where: {
                      $0.type == .subtitle && !previousIDs.contains($0.id)
                  })
        {
            selectSubtitleImmediatelyOrDefer(added.id, for: track.subtitleRole)
        }
    }

    private func startExternalSecurityScopedAccessIfNeeded(for url: URL) {
        guard url.isFileURL, !externalSecurityScopedURLs.contains(url) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        externalSecurityScopedURLs.insert(url)
    }

    func stopExternalSecurityScopedAccess() {
        for url in externalSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        externalSecurityScopedURLs.removeAll()
    }

    private static func selectionProperty(for type: MPVTrackType) -> String {
        switch type {
        case .video: "vid"
        case .audio: "aid"
        case .subtitle: "sid"
        }
    }
}
