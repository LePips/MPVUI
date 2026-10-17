import Dispatch
import Foundation

// Selects and restores media tracks and manages external-track file access.
package extension MPVSession {

    struct ExternalTrack {

        let url: URL
        let type: MPVTrackType
        let select: Bool
        let subtitleRole: MPVSubtitleRole
    }

    private static func selectionProperty(for type: MPVTrackType) -> String {
        switch type {
        case .video: "vid"
        case .audio: "aid"
        case .subtitle: "sid"
        }
    }

    /// Captures the selected tracks and input options after pending local commands finish.
    func externalPlaybackOptions() async -> MPVMediaPackagingOptions {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var options = configuration.additionalOptions.filter {
                    MPVMediaPackagingOptions.sourceOptionNames.contains($0.key)
                        || $0.key.hasPrefix("sub-") || $0.key.hasPrefix("secondary-sub-")
                }
                for name in [
                    "vid",
                    "aid",
                    "sid",
                    "secondary-sid",
                    "audio-delay",
                    "sub-delay",
                    "secondary-sub-delay",
                    "sub-visibility",
                    "secondary-sub-visibility"
                ] {
                    if name == "vid", renderTarget == nil {
                        options[name] = desiredProperties[name] ?? configuration.additionalOptions[name] ?? "auto"
                        continue
                    }
                    if let value = getString(name) ?? desiredProperties[name] {
                        options[name] = value
                    }
                }
                var packaging = MPVMediaPackagingOptions(
                    mpv: options,
                    httpHeaders: getNode("options/http-header-fields")?.arrayValue?.compactMap(\.stringValue)
                )
                let tracks = getNode("track-list")?.arrayValue ?? []
                for (property, type) in [("vid", "video"), ("aid", "audio")] {
                    guard let selected = options[property], let id = Int64(selected),
                          let track = tracks.first(where: {
                              $0.mapValue?["type"]?.stringValue == type && $0.mapValue?["id"]?.integerValue == id
                          })?.mapValue,
                          let index = track["ff-index"]?.integerValue, let nativeIndex = Int32(exactly: index)
                    else {
                        if options[property] != "no", options[property] != "auto" {
                            packaging.requiresRenderer = true
                        }
                        continue
                    }
                    if property == "vid" {
                        packaging.videoIndex = nativeIndex
                    } else {
                        packaging.audioIndex = nativeIndex
                    }
                }
                continuation.resume(returning: packaging)
            }
        }
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
            guard let self, !self.isClosed else { return }
            if let id {
                guard id.type == .subtitle,
                      Self.parseTracks(self.getNode("track-list")).contains(where: { $0.id == id })
                else {
                    self.publish(.error(.invalidSubtitleTrack(id), fatal: false))
                    return
                }
            }
            self.selectSubtitleImmediatelyOrDefer(id, for: role)
        }
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

    func stopExternalSecurityScopedAccess() {
        for url in externalSecurityScopedURLs {
            platform.endSourceAccess(url)
        }
        externalSecurityScopedURLs.removeAll()
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
            role.selectionProperty,
            to: id.map { String($0.mpvID) } ?? "no"
        )
    }

    private func loadExternalTrackImmediately(_ track: ExternalTrack) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Stop releases scoped access while retaining the track descriptions.
        // Replay must reacquire access before the native client reopens them.
        startExternalSecurityScopedAccessIfNeeded(for: track.url)
        let path = platform.mediaPath(track.url)
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

        let selectsAfterAdding = track.type == .subtitle || (track.type == .video && renderTarget == nil)
        let previousIDs = selectsAfterAdding
            ? Set(Self.parseTracks(getNode("track-list")).map(\.id)) : []
        let status = runCommand([
            commandName,
            path,
            track.select && !selectsAfterAdding ? "select" : "auto",
        ])
        if status < 0 {
            publishCommandError(status, context: "Load external \(track.type.rawValue) track")
        } else if selectsAfterAdding, track.select,
                  let added = Self.parseTracks(getNode("track-list")).first(where: {
                      $0.type == track.type && !previousIDs.contains($0.id)
                  })
        {
            if track.type == .subtitle {
                selectSubtitleImmediatelyOrDefer(added.id, for: track.subtitleRole)
            } else {
                // Save the selection without starting video decoding.
                setPropertyImmediatelyOrDefer("vid", to: String(added.mpvID))
            }
        }
    }

    private func startExternalSecurityScopedAccessIfNeeded(for url: URL) {
        guard url.isFileURL, !externalSecurityScopedURLs.contains(url) else { return }
        guard platform.beginSourceAccess(url) else { return }
        externalSecurityScopedURLs.insert(url)
    }
}
