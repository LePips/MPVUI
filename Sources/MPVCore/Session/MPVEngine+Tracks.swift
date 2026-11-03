import CMPV
import Dispatch
import Foundation

public extension MPVSession {

    /// Loads a resource without blocking playback commands and returns its imported tracks.
    /// Requests wait for the current source to load. Cancellation, stop, and source replacement
    /// cancel outstanding work. Failed resources can be retried with the same descriptor.
    func loadExternalTrack(_ source: MPVExternalTrack) async throws -> MPVExternalTrackLoadResult {
        let cancellation = MPVOperationCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard !isClosed, sourceURL != nil, playbackRequestIsActive else {
                        continuation.resume(throwing: MPVPlayerError.clientUnavailable)
                        return
                    }

                    enqueueExternalTrack(
                        ExternalTrack(descriptor: source),
                        cancellation: cancellation,
                        continuation: continuation
                    )
                }
            }
        } onCancel: { [weak self] in
            cancellation.cancel()
            self?.queue.async { [weak self] in
                self?.cancelExternalTrackRequests(matching: cancellation)
            }
        }
    }
}

// Selects and restores media tracks and manages external-track file access.
package extension MPVSession {

    struct ExternalTrack {

        var descriptor: MPVExternalTrack
        var ids: [MPVMediaTrackIdentifier] = []
        var isLoaded = false

        var url: URL {
            descriptor.url
        }

        var type: MPVTrackType {
            descriptor.type
        }

        init(descriptor: MPVExternalTrack) {
            self.descriptor = descriptor
        }

        init(url: URL, type: MPVTrackType, select: Bool, subtitleRole: MPVSubtitleRole) {
            descriptor = MPVExternalTrack(
                url: url,
                type: type,
                selection: select ? (type == .subtitle && subtitleRole == .secondary ? .secondarySubtitle : .selected) : .unselected
            )
        }
    }

    final class ExternalTrackRequest {

        let id: UInt64
        let generation: UInt64
        let track: ExternalTrack
        let cancellation: MPVOperationCancellation
        let selections: [String: Int]
        let selectionRevisions: [String: UInt64]
        var continuation: CheckedContinuation<MPVExternalTrackLoadResult, any Error>?
        var previousIDs: Set<MPVMediaTrackIdentifier> = []
        var previousSelections: [String: String] = [:]

        init(
            id: UInt64,
            generation: UInt64,
            track: ExternalTrack,
            cancellation: MPVOperationCancellation,
            selections: [String: Int],
            selectionRevisions: [String: UInt64],
            continuation: CheckedContinuation<MPVExternalTrackLoadResult, any Error>?
        ) {
            self.id = id
            self.generation = generation
            self.track = track
            self.cancellation = cancellation
            self.selections = selections
            self.selectionRevisions = selectionRevisions
            self.continuation = continuation
        }
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

                packaging.hasSelectedExternalTracks = Self.parseTracks(.array(tracks))
                    .contains { track in
                        guard track.isSelected, track.isExternal else {
                            return false
                        }

                        return track.type != .subtitle || options[(track.subtitleRole ?? .primary).visibilityProperty] != "no"
                    }

                for (property, type) in [("vid", "video"), ("aid", "audio")] {
                    guard let selected = options[property],
                          let id = Int64(selected),
                          let track = tracks.first(
                              where: {
                                  $0.mapValue?["type"]?.stringValue == type && $0.mapValue?["id"]?.integerValue == id
                              }
                          )?.mapValue,
                          let index = track["ff-index"]?.integerValue,
                          let nativeIndex = Int32(exactly: index)
                    else {
                        if options[property] != "no", options[property] != "auto" {
                            packaging.renderingReasons.insert(.trackSelection)
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
            guard let self, !self.isClosed else {
                return
            }

            self.enqueueExternalTrack(.init(url: url, type: type, select: select, subtitleRole: subtitleRole))
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
        guard isFileLoaded else {
            return
        }

        let tracks = pendingExternalTracks

        pendingExternalTracks.removeAll()

        for track in tracks {
            enqueueExternalTrack(track, restoring: true)
        }
        startNextExternalTrackRequest()
    }

    func stopExternalSecurityScopedAccess() {
        let loadingURL = activeExternalTrackRequest?.track.url
        for url in externalSecurityScopedURLs where url != loadingURL {
            platform.endSourceAccess(url)
        }

        externalSecurityScopedURLs = Set(externalSecurityScopedURLs.filter { $0 == loadingURL })
    }

    func enqueueExternalTrack(
        _ track: ExternalTrack,
        restoring: Bool = false,
        cancellation: MPVOperationCancellation = .init(),
        continuation: CheckedContinuation<MPVExternalTrackLoadResult, any Error>? = nil
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        let source = track.descriptor
        let known = externalTracks.map(\.descriptor) + externalTrackRequests.map(\.track.descriptor)
            + [activeExternalTrackRequest?.track.descriptor].compactMap(\.self)
        let conflicts = known.contains { existing in
            guard existing.type == source.type else {
                return false
            }

            if let id = source.clientID, existing.clientID == id, existing.url != source.url {
                return true
            }
            return existing.url == source.url && existing.clientID != nil && source.clientID != nil && existing.clientID != source.clientID
        }
        if conflicts || (source.selection == .secondarySubtitle && source.type != .subtitle)
            || [source.url.absoluteString, source.clientID, source.title, source.language]
            .compactMap(\.self)
            .contains(where: { $0.contains("\0") })
        {
            let error = MPVPlayerError.externalTrackFailed(
                source,
                code: MPV_ERROR_INVALID_PARAMETER.rawValue,
                message: "Invalid or conflicting external-track descriptor."
            )
            continuation?.resume(throwing: error)
            publish(.error(error, fatal: false))
            return
        }

        var selections: [String: Int] = [:]
        if restoring {
            for name in ["vid", "aid", "sid", "secondary-sid"] {
                guard let value = desiredProperties[name],
                      let id = Int(value),
                      let index = track.ids
                          .firstIndex(
                              where: {
                                  $0.mpvID == id && Self.selectionProperty(for: $0.type) == (name == "secondary-sid" ? "sid" : name)
                              }
                          )
                else {
                    continue
                }

                selections[name] = index
            }
        } else if source.selection != .unselected {
            let name = source.selection == .secondarySubtitle ? "secondary-sid" : Self.selectionProperty(for: source.type)
            trackSelectionRevisions[name, default: 0] &+= 1
            selections[name] = 0
        }

        let request = ExternalTrackRequest(
            id: nextNativeCommandID,
            generation: currentGeneration,
            track: track,
            cancellation: cancellation,
            selections: selections,
            selectionRevisions: trackSelectionRevisions,
            continuation: continuation
        )
        nextNativeCommandID &+= 1
        externalTrackRequests.append(request)
        startNextExternalTrackRequest()
    }

    func startNextExternalTrackRequest() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard activeExternalTrackRequest == nil, isFileLoaded, let handle, !isClosed, !externalTrackRequests.isEmpty else {
            return
        }

        let request = externalTrackRequests.removeFirst()
        activeExternalTrackRequest = request

        guard request.generation == currentGeneration, !request.cancellation.isCancelled else {
            finishExternalTrackRequest(request, status: MPV_ERROR_COMMAND.rawValue)
            return
        }

        let track = request.track
        startExternalSecurityScopedAccessIfNeeded(for: track.url)
        request.previousIDs = Set(Self.parseTracks(getNode("track-list")).map(\.id))
        for name in ["vid", "aid", "sid", "secondary-sid"] {
            request.previousSelections[name] = desiredProperties[name] ?? getString(name)
        }

        let path = platform.mediaPath(track.url)
        if !tracks(for: request).isEmpty {
            finishExternalTrackRequest(request, status: 0)
            return
        }

        let commandName = track.type == .subtitle ? "sub-add" : "\(track.type.rawValue)-add"
        let arguments = [commandName, path, "auto", track.descriptor.title ?? "", track.descriptor.language ?? ""]
        var pointers: [UnsafePointer<CChar>?] = arguments.map { argument in
            strdup(argument).map { UnsafePointer($0) }
        }
        pointers.append(nil)
        defer {
            for case let pointer? in pointers {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }
        let status = mpv_command_async(handle, request.id, &pointers)
        if status < 0 {
            finishExternalTrackRequest(request, status: status)
        }
    }

    func finishExternalTrackRequest(_ request: ExternalTrackRequest, status: Int32) {
        guard activeExternalTrackRequest === request else {
            return
        }

        activeExternalTrackRequest = nil
        defer {
            startNextExternalTrackRequest()
        }

        guard request.generation == currentGeneration, !request.cancellation.isCancelled else {
            if request.generation == currentGeneration, isFileLoaded {
                // Cancellation can race with a successful native reply. Remove only
                // tracks introduced by this request, never an existing shared resource.
                for track in tracks(for: request) where !request.previousIDs.contains(track.id) {
                    _ = runCommand([track.type == .subtitle ? "sub-remove" : "\(track.type.rawValue)-remove", String(track.mpvID)])
                }
                restoreSelections(after: request)
                refreshMediaInformation()
            }
            request.continuation?.resume(throwing: CancellationError())
            request.continuation = nil
            releaseUnusedExternalAccess(for: request.track.url)
            return
        }

        let added = tracks(for: request)
        guard status >= 0, !added.isEmpty else {
            let code = status < 0 ? status : MPV_ERROR_NOTHING_TO_PLAY.rawValue
            let error = MPVPlayerError.externalTrackFailed(request.track.descriptor, code: code, message: mpvErrorMessage(code))
            request.continuation?.resume(throwing: error)
            request.continuation = nil
            publish(.error(error, fatal: false))
            releaseUnusedExternalAccess(for: request.track.url)
            return
        }

        var registered = request.track
        registered.ids = added.map(\.id)
        registered.isLoaded = true
        if let index = externalTracks.firstIndex(where: { $0.url == registered.url && $0.type == registered.type }) {
            let previous = externalTracks[index].descriptor
            let source = registered.descriptor
            registered.descriptor = .init(
                url: source.url,
                type: source.type,
                clientID: source.clientID ?? previous.clientID,
                title: source.title ?? previous.title,
                language: source.language ?? previous.language,
                selection: source.selection
            )
            externalTracks[index] = registered
        } else {
            externalTracks.append(registered)
        }

        restoreSelections(after: request)
        for name in ["vid", "aid", "sid", "secondary-sid"] {
            guard let index = request.selections[name],
                  added.indices.contains(index),
                  trackSelectionRevisions[name, default: 0] == request.selectionRevisions[name, default: 0]
            else {
                continue
            }

            if name == "sid" || name == "secondary-sid" {
                selectSubtitleImmediatelyOrDefer(added[index].id, for: name == "sid" ? .primary : .secondary)
            } else {
                setPropertyImmediatelyOrDefer(name, to: String(added[index].mpvID))
            }
        }
        refreshMediaInformation()
        refreshTextSubtitleSnapshot()
        let result = MPVExternalTrackLoadResult(
            source: request.track.descriptor,
            generation: currentGeneration,
            tracks: latestSnapshot.mediaInformation.tracks.filter { registered.ids.contains($0.id) }
        )
        publish(.externalTrackLoaded(result))
        request.continuation?.resume(returning: result)
        request.continuation = nil
    }

    func cancelExternalTrackRequests(matching cancellation: MPVOperationCancellation? = nil, discardingNativeRequest: Bool = false) {
        let canceled = externalTrackRequests.filter { cancellation == nil || $0.cancellation === cancellation }
        externalTrackRequests.removeAll { cancellation == nil || $0.cancellation === cancellation }
        for request in canceled {
            request.cancellation.cancel()
            request.continuation?.resume(throwing: CancellationError())
            request.continuation = nil
            releaseUnusedExternalAccess(for: request.track.url)
        }
        if let request = activeExternalTrackRequest, cancellation == nil || request.cancellation === cancellation {
            request.cancellation.cancel()
            if let handle {
                mpv_abort_async_command(handle, request.id)
            }
            request.continuation?.resume(throwing: CancellationError())
            request.continuation = nil
            if discardingNativeRequest {
                activeExternalTrackRequest = nil
            }
        }
    }

    func releaseUnusedExternalAccess(for url: URL) {
        guard externalSecurityScopedURLs.contains(url),
              !externalTracks.contains(where: { $0.url == url }),
              !externalTrackRequests.contains(where: { $0.track.url == url }),
              activeExternalTrackRequest?.track.url != url
        else {
            return
        }

        platform.endSourceAccess(url)
        externalSecurityScopedURLs.remove(url)
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

    private func tracks(for request: ExternalTrackRequest) -> [MPVMediaTrack] {
        Self.parseTracks(getNode("track-list"))
            .filter {
                $0.type == request.track.type && $0.isExternal && $0.externalURL == request.track.url
            }
    }

    private func restoreSelections(after request: ExternalTrackRequest) {
        // Adding with "auto" normally preserves selection. Explicitly restore it
        // for native auto-selection cases, including selections made during I/O.
        var selections = request.previousSelections
        for (name, value) in desiredProperties where ["vid", "aid", "sid", "secondary-sid"].contains(name) {
            selections[name] = value
        }
        if selections["sid"] != nil, selections["secondary-sid"] != nil {
            _ = setPropertyImmediately("sid", to: "no")
            _ = setPropertyImmediately("secondary-sid", to: "no")
        }
        for name in ["vid", "aid", "sid", "secondary-sid"] {
            guard var value = selections[name] else {
                continue
            }

            if let id = Int(value), externalTracks.contains(
                where: { track in
                    !track.isLoaded && track.ids
                        .contains { $0.mpvID == id && Self.selectionProperty(for: $0.type) == (name == "secondary-sid" ? "sid" : name) }
                }
            ) {
                value = "no"
            }
            _ = setPropertyImmediately(name, to: value)
        }
    }

    private func startExternalSecurityScopedAccessIfNeeded(for url: URL) {
        guard url.isFileURL, !externalSecurityScopedURLs.contains(url), platform.beginSourceAccess(url) else {
            return
        }

        externalSecurityScopedURLs.insert(url)
    }
}
