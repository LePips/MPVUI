import Combine
import Foundation
import GLKit
import MPVKit

// TODO: init with configuration
//       - log level
public class MPVClient {
    
    // events
    
    var eventQueue: DispatchQueue = .init(label: "com.mpvui.eventqueue", qos: .userInitiated)
    var eventPublisher: CurrentValueSubject<MPVEvent?, Never> = .init(nil)
    var eventObservers: AtomicDict<EventObserverKey, CurrentValueSubject<Void, Never>> = .init()
    
    public var core: OpaquePointer!
    
    public var events: AnyPublisher<MPVEvent, Never> {
        eventPublisher
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }
    
    public var logLevel: LogLevel? {
        willSet {
            let level = newValue?.rawValue ?? "no"
            mpv_request_log_messages(core, level)
        }
    }
    
    public init() {
        core = mpv_create()
        
        mpv_initialize(core)
        mpv_set_wakeup_callback(
            core,
            mpvDidWake,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
    }
}

private func mpvDidWake(context: UnsafeMutableRawPointer?) {
    unsafeBitCast(context, to: MPVClient.self)
        .waitForEvents()
}
