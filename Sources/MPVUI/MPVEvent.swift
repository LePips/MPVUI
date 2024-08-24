import Foundation
import MPVKit

// Comments are from below and were summarized by ChatGPT.
// - Some cases have been renamed for clarity
// - `none` is ommitted.
//
// - https://github.com/mpv-player/mpv/blob/master/libmpv/client.h#L1242

public enum MPVEvent: Int {
    
    /// Happens when the player quits. The player enters a state where it tries to disconnect all clients.
    case shutdown = 1
    
    /// Log message events. See mpv_request_log_messages().
    case logMessage = 2
    
    /// Reply to a mpv_get_property_async() request.
    case getPropertyReply = 3
    
    /// Reply to a mpv_set_property_async() request.
    case setPropertyReply = 4
    
    /// Reply to a mpv_command_async() or mpv_command_node_async() request.
    case commandReply = 5
    
    /// Notification before playback start of a file.
    case startFile = 6
    
    /// Notification after playback end.
    case endFile = 7
    
    /// Notification when the file has been loaded and decoding starts.
    case fileLoaded = 8
    
    /// Idle mode was entered. Deprecated.
    case idle = 11
    
    /// Sent every time after a video frame is displayed. Deprecated.
    case tick = 14
    
    /// Triggered by the script-message input command.
    case clientMessage = 16
    
    /// Happens after video changed in some way, such as resolution or format changes.
    case videoReconfig = 17
    
    /// Happens after audio changes, such as format or device changes.
    case audioReconfig = 18
    
    /// Happens when a seek was initiated.
    case seek = 20
    
    /// Playback was reinitialized, usually after a seek or at start of playback.
    case playbackRestart = 21
    
    /// Event sent due to mpv_observe_property().
    case propertyChange = 22
    
    /// Happens if the internal per-mpv_handle ringbuffer overflows.
    case queueOverflow = 24
    
    /// Triggered if a hook handler was registered with mpv_hook_add().
    case hook = 25
    
    init?(event: UInt32) {
        self.init(rawValue: Int(event))
    }
}
