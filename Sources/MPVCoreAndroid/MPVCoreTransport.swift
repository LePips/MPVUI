import CMPV
import Foundation
import MPVCore

func session(_ handle: UnsafeMutableRawPointer?) -> MPVSession? {
    handle.map { Unmanaged<MPVSession>.fromOpaque($0).takeUnretainedValue() }
}

func copiedString(_ value: MPVCoreString) -> String? {
    guard value.length <= 1024 * 1024, value.length == 0 || value.data != nil else { return nil }
    let bytes = UnsafeBufferPointer(start: value.data, count: value.length)
    guard !bytes.contains(0) else { return nil }
    return String(bytes: bytes, encoding: .utf8)
}

func copiedRecord(_ value: MPVCoreString) -> CoreValue? {
    guard value.length > 0, value.length <= 32 * 1024 * 1024, value.data != nil else { return nil }
    return try? CoreValue.decode(UnsafeBufferPointer(start: value.data, count: value.length))
}

/// Submits a versioned command to the sole native session owner.
@_cdecl("mpvcore_session_send")
public func coreSessionSend(
    _ handle: UnsafeMutableRawPointer?,
    _ command: UnsafePointer<MPVCoreCommand>?,
    _ operation: UnsafeMutablePointer<MPVCoreOperation>?
) -> Int32 {
    guard let session = session(handle), let value = command?.pointee,
          value.version == MPVCORE_ABI_VERSION, value.size == MemoryLayout<MPVCoreCommand>.size,
          value.value.isFinite, (0 ... 2).contains(value.track_type), (-1 ... 1).contains(value.role),
          value.kind == 1 ? (-1 ... 1).contains(value.flags) : (0 ... 1).contains(value.flags),
          (0 ... 1).contains(value.has_value), value.string_count <= 1024,
          value.string_count == 0 || value.strings != nil else { return MPV_ERROR_INVALID_PARAMETER.rawValue }
    var strings: [String] = []
    for item in UnsafeBufferPointer(start: value.strings, count: value.string_count) {
        guard let string = copiedString(item) else { return MPV_ERROR_INVALID_PARAMETER.rawValue }
        strings.append(string)
    }
    let type: MPVTrackType = value.track_type == 0 ? .video : value.track_type == 1 ? .audio : .subtitle
    let id = MPVMediaTrackIdentifier(type: type, mpvID: Int(clamping: value.track_id))
    let role: MPVSubtitleRole = value.role == 1 ? .secondary : .primary
    func source() -> URL? {
        guard let text = strings.first, !text.isEmpty else { return nil }
        if let url = URL(string: text), url.scheme != nil {
            return url
        }
        return URL(fileURLWithPath: text)
    }
    let request: MPVSessionCommand
    switch value.kind {
    case 1:
        guard let url = source(), (-1 ... 1).contains(value.flags),
              value.has_value == 0 || Duration(mpvSeconds: value.value) != nil else { return MPV_ERROR_INVALID_PARAMETER.rawValue }
        request = .load(
            url,
            autoPlay: value.flags == -1 ? nil : value.flags != 0,
            startTime: value.has_value == 0 ? nil : Duration(mpvSeconds: value.value)
        )
    case 2: request = .play
    case 3: request = .pause
    case 4: request = .togglePlayback
    case 5: request = .stop
    case 6, 7:
        guard let time = Duration(mpvSeconds: value.value) else { return MPV_ERROR_INVALID_PARAMETER.rawValue }
        request = value.kind == 6 ? .seek(time) : .seekRelative(time)
    case 8: request = .frameStep(backward: value.flags != 0)
    case 9: request = .volume(value.value)
    case 10: request = .mute(value.flags != 0)
    case 11: request = .playbackRate(value.value)
    case 12: request = .selectTrack(id)
    case 13: request = .selectSubtitle(value.track_id < 0 ? nil : id, role: role)
    case 14: request = .disableTrack(type)
    case 15: request = .interceptTextSubtitles(value.flags != 0)
    case 16: request = .diagnostics(value.flags != 0)
    case 17:
        guard strings.count == 2 else { return MPV_ERROR_INVALID_PARAMETER.rawValue }
        request = .property(strings[0], strings[1])
    case 18:
        guard !strings.isEmpty else { return MPV_ERROR_INVALID_PARAMETER.rawValue }
        request = .native(strings)
    case 19:
        guard let url = source() else { return MPV_ERROR_INVALID_PARAMETER.rawValue }
        request = .externalTrack(url, type: type, select: value.flags != 0, role: value.role == -1 ? nil : role)
    case 20: request = .clearError
    case 21: request = .toggleMute
    default: return MPV_ERROR_INVALID_PARAMETER.rawValue
    }
    do {
        let result = try session.send(request)
        operation?.pointee = .init(id: result.id, generation: result.generation)
        return 0
    } catch { return MPV_ERROR_UNINITIALIZED.rawValue }
}

/// Copies the latest complete domain state into an owned ABI record.
@_cdecl("mpvcore_session_snapshot")
public func coreSessionSnapshot(_ handle: UnsafeMutableRawPointer?) -> MPVCoreBuffer {
    guard let session = session(handle) else { return .init() }
    return CoreValue.snapshot(session.snapshot).ownedBuffer()
}

private final class Subscription: @unchecked Sendable {

    let session: MPVSession
    let id = UUID()
    let context: UnsafeMutableRawPointer?
    let delivery: MPVCoreDelivery
    var previous: MPVSessionSnapshot?

    init(session: MPVSession, context: UnsafeMutableRawPointer?, delivery: @escaping MPVCoreDelivery) {
        self.session = session
        self.context = context
        self.delivery = delivery
    }

    func deliver(_ event: MPVSessionEvent) {
        switch event {
        case let .snapshot(snapshot):
            var comparison = previous
            comparison?.position = snapshot.position
            comparison?.buffer = snapshot.buffer
            comparison?.diagnostics = snapshot.diagnostics
            let continuous = comparison == snapshot
            previous = snapshot
            delivery(context, continuous ? 6 : 1, snapshot.generation, CoreValue.snapshot(snapshot).ownedBuffer())
        case let .log(log):
            delivery(
                context,
                2,
                session.currentGeneration,
                CoreValue.record([
                    "prefix": .string(log.prefix),
                    "level": .string(log.level.rawValue),
                    "message": .string(log.message),
                ])
                .ownedBuffer()
            )
        }
    }
}

/// Begins event-driven delivery. The subscriber must fence cancellation before freeing its context.
@_cdecl("mpvcore_session_subscribe")
public func coreSessionSubscribe(
    _ handle: UnsafeMutableRawPointer?,
    _ context: UnsafeMutableRawPointer?,
    _ delivery: MPVCoreDelivery?
) -> UnsafeMutableRawPointer? {
    guard let session = session(handle), let delivery else { return nil }
    let subscription = Subscription(session: session, context: context, delivery: delivery)
    session.queue.sync {
        session.nativeObservers[subscription.id] = { [weak subscription] event in subscription?.deliver(event) }
        subscription.deliver(.snapshot(session.latestSnapshot))
    }
    return Unmanaged.passRetained(subscription).toOpaque()
}

/// Stops delivery and waits for in-flight native callbacks to finish.
@_cdecl("mpvcore_subscription_release")
public func coreSubscriptionRelease(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    let value = Unmanaged<Subscription>.fromOpaque(handle).takeRetainedValue()
    value.session.queue.sync { _ = value.session.nativeObservers.removeValue(forKey: value.id) }
}

private final class Query: @unchecked Sendable {

    let context: UnsafeMutableRawPointer?
    let delivery: MPVCoreDelivery
    let releaseContext: MPVCoreContextRelease?
    var task: Task<Void, Never>?
    init(context: UnsafeMutableRawPointer?, delivery: @escaping MPVCoreDelivery, release: MPVCoreContextRelease?) {
        self.context = context
        self.delivery = delivery
        releaseContext = release
    }

    deinit { releaseContext?(context) }
}

/// Queries copied timed subtitle values without changing live subtitle selections.
@_cdecl("mpvcore_query_subtitles")
public func coreQuerySubtitles(
    _ handle: UnsafeMutableRawPointer?,
    _ trackType: Int32,
    _ trackID: Int64,
    _ context: UnsafeMutableRawPointer?,
    _ delivery: MPVCoreDelivery?,
    _ releaseContext: MPVCoreContextRelease?
) -> UnsafeMutableRawPointer? {
    guard let session = session(handle), let delivery, (0 ... 2).contains(trackType),
          trackID > 0, let id = Int(exactly: trackID) else { return nil }
    let type: MPVTrackType = trackType == 0 ? .video : trackType == 1 ? .audio : .subtitle
    let query = Query(context: context, delivery: delivery, release: releaseContext)
    let generation = session.snapshot.generation
    query.task = Task { [query] in
        do {
            let timeline = try await session.textSubtitleSnapshots(for: .init(type: type, mpvID: id))
            try Task.checkCancellation()
            guard generation == session.snapshot.generation else { throw CancellationError() }
            query.delivery(query.context, 3, generation, CoreValue.timeline(timeline).ownedBuffer())
        } catch is CancellationError {
            query.delivery(query.context, 4, generation, CoreValue.null.ownedBuffer())
        } catch {
            query.delivery(
                query.context,
                5,
                generation,
                CoreValue.failure(error as? MPVPlayerError ?? .commandFailed(
                    context: "Subtitle query",
                    code: -1,
                    message: error.localizedDescription
                ))
                .ownedBuffer()
            )
        }
    }
    return Unmanaged.passRetained(query).toOpaque()
}

/// Cancels and releases a query, retaining callback resources until completion.
@_cdecl("mpvcore_query_release")
public func coreQueryRelease(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    let query = Unmanaged<Query>.fromOpaque(handle).takeRetainedValue()
    query.task?.cancel()
    query.task = nil
}

private final class SurfaceOwner: @unchecked Sendable {

    let context: UnsafeMutableRawPointer?
    let release: MPVCoreContextRelease?
    init(_ context: UnsafeMutableRawPointer?, release: MPVCoreContextRelease?) {
        self.context = context
        self.release = release
    }

    deinit { release?(context) }
}

/// Attaches a retained platform surface, retiring the previous native renderer first.
@_cdecl("mpvcore_session_surface")
public func coreSessionSurface(
    _ handle: UnsafeMutableRawPointer?,
    _ address: Int64,
    _ context: UnsafeMutableRawPointer?,
    _ release: MPVCoreContextRelease?,
    _ display: MPVCoreString
) -> Int32 {
    guard let session = session(handle), !session.snapshot.isClosed else { return MPV_ERROR_UNINITIALIZED.rawValue }
    if address == 0 {
        session.detachCurrentRenderTargetSynchronously()
        return 0
    }
    guard display.length == 0 || copiedRecord(display)?.isRecord == true else { return MPV_ERROR_INVALID_PARAMETER.rawValue }
    let owner = SurfaceOwner(context, release: release)
    let fields = copiedRecord(display)?.fields ?? [:]
    let hdr = fields["hdr10"]?.bool == true || fields["hlg"]?.bool == true || fields["dolbyVision"]?.bool == true
    let target = MPVRenderTarget(
        layerAddress: address,
        layerOwner: owner,
        drawableWidth: 0,
        drawableHeight: 0,
        usesExtendedDynamicRange: false,
        displaySupportsExtendedDynamicRange: hdr,
        outputHeadroom: 1,
        displayCapabilities: .init(
            hdrSupport: hdr ? .supported : .unsupported,
            supportsWideGamut: fields["wideGamut"]?.bool,
            supportsHDR10: fields["hdr10"]?.bool,
            supportsHLG: fields["hlg"]?.bool,
            supportsDolbyVision: fields["dolbyVision"]?.bool,
            refreshRate: fields["refreshRate"]?.double
        ),
        configuredDynamicRange: MPVAndroidOutputPolicy.output(
            session.configuration,
            display: .init(
                supportsHDR10: fields["hdr10"]?.bool,
                supportsHLG: fields["hlg"]?.bool,
                supportsDolbyVision: fields["dolbyVision"]?.bool
            )
        ) == .gpu ? .sdr : .unknown
    )
    session.attach(to: target)
    return 0
}

/// Updates Android surface geometry on the same queue as playback commands.
@_cdecl("mpvcore_session_resize")
public func coreSessionResize(_ handle: UnsafeMutableRawPointer?, _ address: Int64, _ width: Int32, _ height: Int32) {
    guard let session = session(handle), width > 0, height > 0 else { return }
    session.queue.async {
        guard !session.isClosed, session.renderTarget?.layerAddress == address else { return }
        session.renderTarget = session.renderTarget?.replacingDrawableSize(width: Int(width), height: Int(height))
        if session.handle != nil {
            session.setPropertyImmediatelyOrDefer("android-surface-size", to: "\(width)x\(height)")
        }
    }
}

/// Evaluates an accumulated feature request and returns a copied typed result.
@_cdecl("mpvcore_session_request_features")
public func coreSessionRequestFeatures(_ handle: UnsafeMutableRawPointer?, _ mask: UInt32) -> MPVCoreBuffer {
    guard let session = session(handle), mask < (1 << MPVVideoFeature.allCases.count) else { return .init() }
    let features = Set(MPVVideoFeature.allCases.enumerated().compactMap { index, feature in mask & (1 << index) != 0 ? feature : nil })
    return CoreValue.featureResult(session.requestVideoFeatures(features)).ownedBuffer()
}
