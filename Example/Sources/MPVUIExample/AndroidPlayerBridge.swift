#if SKIP
// SKIP @bridgeMembers
public final class AndroidPlayerBridge {

    // SKIP @nobridge
    let core: AndroidPlayback

    public init(
        autoPlay: Bool,
        loop: Bool,
        rate: Double,
        volume: Double,
        start: Double,
        hasStart: Bool,
        buffer: Double,
        cache: Double,
        optionNames: [String],
        optionValues: [String]
    ) {
        core = AndroidPlayback(autoPlay, loop, rate, volume, start, hasStart, buffer, cache, optionNames, optionValues)
    }

    public func retainSession() -> Int64 {
        core.retainSession()
    }

    public func prepareLoad(_ autoPlay: Bool) -> Bool {
        core.prepareLoad(autoPlay)
    }

    public func requestAudioFocus() -> Bool {
        core.requestAudioFocus()
    }

    public func cancelAudioResume() {
        core.cancelAudioResume()
    }

    public func observePictureInPicture(_ callback: @escaping (Bool, Bool, Bool, Bool, String?) -> Void) {
        core.observePictureInPicture(callback)
    }

    public func startPictureInPicture() {
        core.startPictureInPicture()
    }

    public func clearPictureInPictureError() {
        core.clearPictureInPictureError()
    }

    public func openFile(_ callback: @escaping (String, String) -> Void) {
        core.openFile(callback)
    }

    public func close() {
        core.close()
    }
}
#endif
