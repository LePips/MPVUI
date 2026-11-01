import CMPV
import Foundation

// Supplies native overlays and completes picture-in-picture seek requests.
package extension MPVSession {

    struct PiPSeek {

        let id: UUID
        let target: Duration
        let continuation: CheckedContinuation<Bool, Never>
        var sawSeek = false
    }

    private struct NativePiPCompositionRequest: Sendable {

        let id: UInt64
        let generation: UInt64
        let handleCreation: UInt64
    }

    /// Waits until the native output has enqueued a frame in the requested
    /// subtitle mode before AVKit adopts its video-only sample-buffer source.
    func setNativePictureInPictureComposition(_ enabled: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }

        let request: NativePiPCompositionRequest? = await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil)
                    return
                }

                self.nativePiPCompositionRequestID &+= 1
                guard self.handle != nil, self.videoOutput == .sampleBuffer,
                      self.setPropertyImmediately("avfoundation-pip-active", to: enabled ? "yes" : "no") >= 0
                else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: NativePiPCompositionRequest(
                    id: self.nativePiPCompositionRequestID,
                    generation: self.currentGeneration,
                    handleCreation: self.lifecycleDiagnostics.handlesCreated
                ))
            }
        }
        guard let request else { return false }

        let clock = ContinuousClock()
        let start = clock.now
        while !Task.isCancelled, start.duration(to: clock.now) < .seconds(2) {
            let acknowledged: Bool? = await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    guard let self, self.isCurrentNativePiPRequest(request),
                          self.getFlag("avfoundation-pip-active") == enabled
                    else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let mode = self.getInt64("avfoundation-video-statistics/osd-mode")
                    if mode == 3 {
                        continuation.resume(returning: nil)
                        return
                    }
                    let composite = enabled || self.getFlag("avfoundation-composite-osd") == true
                        || self.renderTarget?.osdLayerAddress == nil
                    continuation.resume(returning: mode == (composite ? 2 : 1))
                }
            }
            if acknowledged == true {
                return true
            }
            if acknowledged == nil {
                break
            }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        // A failed automatic arm must not leave the inline subtitles hidden.
        // Never undo a newer request or mutate a replacement media session.
        if enabled {
            await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    if let self, self.isCurrentNativePiPRequest(request) {
                        _ = self.setPropertyImmediately("avfoundation-pip-active", to: "no")
                    }
                    continuation.resume()
                }
            }
        }
        return false
    }

    /// ID 63 is reserved for MPVUI's PiP overlay. The native VO composites it
    /// with the remaining OSD groups in frame space, including paused redraws.
    func setPictureInPictureOverlay(_ bitmap: MPVVideoOverlayBitmap?) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, self.handle != nil else {
                    continuation.resume(returning: false)
                    return
                }
                guard let bitmap else {
                    continuation.resume(returning: self.runCommand(["overlay-remove", "63"]) >= 0)
                    return
                }
                guard self.videoOutput == .sampleBuffer,
                      // RPU metadata describes unmodified pixels. The native
                      // compositor deliberately preserves these frames intact.
                      self.getInt64("current-tracks/video/dolby-vision-profile") == nil,
                      let width = self.getInt64("osd-width"),
                      let height = self.getInt64("osd-height"),
                      width > 0, height > 0, width <= 16384, height <= 16384
                else {
                    _ = self.runCommand(["overlay-remove", "63"])
                    continuation.resume(returning: false)
                    return
                }

                // runCommand is synchronous. This buffer remains pinned until
                // mpv copies every row; no pointer escapes withUnsafeBytes.
                let status = bitmap.bytes.withUnsafeBytes { bytes -> Int32 in
                    guard let address = bytes.baseAddress else { return MPV_ERROR_INVALID_PARAMETER.rawValue }

                    return self.runCommand([
                        "overlay-add",
                        "63",
                        "0",
                        "0",
                        "&\(UInt(bitPattern: address))",
                        "0",
                        "bgra",
                        String(bitmap.width),
                        String(bitmap.height),
                        String(bitmap.stride),
                        String(width),
                        String(height),
                    ])
                }

                if status < 0 {
                    _ = self.runCommand(["overlay-remove", "63"])
                }

                continuation.resume(returning: status >= 0)
            }
        }
    }

    func clearPictureInPictureOverlay() {
        queue.async { [weak self] in
            guard let self, self.handle != nil else { return }

            _ = self.runCommand(["overlay-remove", "63"])
        }
    }

    func seekForPictureInPicture(to time: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, self.handle != nil, self.isFileLoaded || self.didReachEnd, self.lastSeekable else {
                    continuation.resume(returning: false)
                    return
                }

                self.completePiPSeek(false)

                // Deliver already queued restarts before registering a new seek.
                self.drainEvents()

                guard self.handle != nil, self.isFileLoaded || self.didReachEnd, self.lastSeekable else {
                    continuation.resume(returning: false)
                    return
                }

                let target = self.lastDuration > .zero
                    ? clamped(time, to: .zero ... self.lastDuration) : time.clampPositiveOrZero

                if self.didReachEnd, target >= self.lastDuration {
                    continuation.resume(returning: true)
                    return
                }

                let id = UUID()
                self.pendingPiPSeek = PiPSeek(id: id, target: target, continuation: continuation)

                if self.didReachEnd, let sourceURL = self.sourceURL {
                    // EOF retires the VO. Reopen the same source paused so a
                    // backward PiP skip supplies a new destination frame and
                    // timebase before completing AVKit's request.
                    self.pendingPiPSeek?.sawSeek = true
                    self.pendingStartTime = target
                    self.pendingSeekAfterLoad = nil
                    self.lastPosition = target
                    self.shouldAutoPlay = false
                    self.isPaused = true
                    self.didReachEnd = false
                    self.playbackRequestIsActive = true
                    self.fatalPlaybackError = nil
                    self.needsSourceLoad = true
                    self.pendingExternalTracks = self.externalTracks
                    self.startSecurityScopedAccessIfNeeded(for: sourceURL)
                    self.publishState(.loading)
                    self.loadPendingSourceIfPossible()
                } else {
                    let status = self.runCommand(["seek", Self.format(target), "absolute+exact"])

                    guard status >= 0 else {
                        self.publishCommandError(status, context: "Seek from picture in picture")
                        self.completePiPSeek(false)
                        return
                    }
                }

                self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, self.pendingPiPSeek?.id == id else { return }

                    self.completePiPSeek(false)
                }
            }
        }
    }

    func completePiPSeek(_ success: Bool) {
        let request = pendingPiPSeek

        pendingPiPSeek = nil
        request?.continuation.resume(returning: success)
    }

    private func isCurrentNativePiPRequest(_ request: NativePiPCompositionRequest) -> Bool {
        handle != nil && nativePiPCompositionRequestID == request.id
            && currentGeneration == request.generation && lifecycleDiagnostics.handlesCreated == request.handleCreation
    }
}
