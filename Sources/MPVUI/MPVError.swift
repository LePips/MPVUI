import Foundation

// Comments are from below and were summarized by ChatGPT.
// - Some cases have been renamed for clarity
// - `success` is ommitted.
//
// - https://github.com/mpv-player/mpv/blob/master/libmpv/client.h#L278

public enum MPVError: Int, Error {
    
    /// Event queue is full.
    case eventQueueFull = -1
    
    /// Memory allocation failed.
    case noMemory = -2
    
    /// The mpv core wasn't configured and initialized yet.
    case uninitialized = -3
    
    /// Generic catch-all error for invalid or unsupported parameters.
    case invalidParameter = -4
    
    /// The option does not exist.
    case optionNotFound = -5
    
    /// Unsupported MPV_FORMAT for option.
    case optionFormat = -6
    
    /// Setting the option failed, possibly due to parse errors.
    case optionError = -7
    
    /// The accessed property doesn't exist.
    case propertyNotFound = -8
    
    /// Unsupported MPV_FORMAT for property.
    case propertyFormat = -9
    
    /// The property is not available, possibly due to the associated subsystem being inactive.
    case propertyUnavailable = -10
    
    /// Error setting or getting a property.
    case propertyError = -11
    
    /// General error when running a command.
    case command = -12
    
    /// Generic error on loading.
    case loadingFailed = -13
    
    /// Initializing the audio output failed.
    case audioOutputInitFailed = -14
    
    /// Initializing the video output failed.
    case videoOutputInitFailed = -15
    
    /// There was no audio or video data to play.
    case nothingToPlay = -16
    
    /// Unable to determine the file format, or the file is too corrupted.
    case unknownFormat = -17
    
    /// Generic error for unfulfilled system requirements.
    case unsupported = -18
    
    /// The API function called is a stub only.
    case notImplemented = -19
    
    /// Unspecified error.
    case generic = -20
    
    init?(status: Int32) {
        self.init(rawValue: Int(status))
    }
}
