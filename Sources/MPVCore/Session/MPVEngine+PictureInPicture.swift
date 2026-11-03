import CMPV
import Foundation

// Supplies native overlays and completes picture-in-picture seek requests.
package extension MPVSession {

    private struct NativePiPCompositionRequest: Sendable {

        let id: UInt64
        let generation: UInt64
        let handleCreation: UInt64
    }

    /// Waits until the native output has enqueued a frame in the requested
    /// subtitle mode before AVKit adopts its video-only sample-buffer source.
    func setNativePictureInPictureComposition(_ enabled: Bool) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }

        let request: NativePiPCompositionRequest? = await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                self.nativePiPCompositionRequestID &+= 1
                guard self.handle != nil,
                      self.videoOutput == .sampleBuffer,
                      self.setPropertyImmediately("avfoundation-pip-active", to: enabled ? "yes" : "no") >= 0
                else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(
                    returning: NativePiPCompositionRequest(
                        id: self.nativePiPCompositionRequestID,
                        generation: self.currentGeneration,
                        handleCreation: self.lifecycleDiagnostics.handlesCreated
                    )
                )
            }
        }
        guard let request else {
            return false
        }

        let clock = ContinuousClock()
        let start = clock.now
        while !Task.isCancelled, start.duration(to: clock.now) < .seconds(2) {
            let acknowledged: Bool? = await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    guard let self,
                          self.isCurrentNativePiPRequest(request),
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
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                break
            }
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
                      width > 0,
                      height > 0,
                      width <= 16384,
                      height <= 16384
                else {
                    _ = self.runCommand(["overlay-remove", "63"])
                    continuation.resume(returning: false)
                    return
                }

                // runCommand is synchronous. This buffer remains pinned until
                // mpv copies every row; no pointer escapes withUnsafeBytes.
                let status = bitmap.bytes.withUnsafeBytes { bytes -> Int32 in
                    guard let address = bytes.baseAddress else {
                        return MPV_ERROR_INVALID_PARAMETER.rawValue
                    }

                    return self.runCommand(
                        [
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
                        ]
                    )
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
        await (try? performSeek(to: time, timeout: .seconds(8), pausesAfterEnd: true)) != nil
    }

    private func isCurrentNativePiPRequest(_ request: NativePiPCompositionRequest) -> Bool {
        handle != nil && nativePiPCompositionRequestID == request.id
            && currentGeneration == request.generation && lifecycleDiagnostics.handlesCreated == request.handleCreation
    }
}
