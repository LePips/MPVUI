import Foundation

/// Platform operations invoked only on the session's serialized native queue.
package struct MPVPlatformServices: Sendable {

    package var initialOptions: @Sendable (MPVSessionConfiguration, MPVRenderTarget?, MPVVideoOutput) -> [(String, String)] = { _, _, _ in
        []
    }

    package var optionalInitialOptions: @Sendable (MPVSessionConfiguration) -> [(String, String)] = { _ in [] }
    package var videoOutputName: @Sendable (MPVVideoOutput) -> String = { _ in "null" }
    package var mediaPath: @Sendable (URL) -> String = { $0.isFileURL ? $0.path : $0.absoluteString }
    package var prepareHandle: @Sendable (OpaquePointer) -> Int32 = { _ in 0 }
    package var lowPowerMode: @Sendable () -> Bool = { false }
    package var beginSourceAccess: @Sendable (URL) -> Bool = { _ in false }
    package var endSourceAccess: @Sendable (URL) -> Void = { _ in }
    package var codecSupportsHardware: @Sendable (String?) -> Bool? = { _ in nil }

    package init() {}
}

/// Native rendering must detach and join before the adapter releases its owner.
package protocol MPVNativeSurfaceOwner: AnyObject {

    func beginNativeResizeTransaction()

    func endNativeResizeTransaction()

    func invalidateDrawablePoolAfterNativeTeardown() -> Bool
}

/// Copied color settings; graphics framework objects remain in the platform adapter.
package struct MPVSurfaceColorConfiguration: Equatable, Sendable {

    package let options: [(String, String)]
    package let pixelFormat: UInt
    package let status: MPVRenderColorStatus

    package init(options: [(String, String)], pixelFormat: UInt, status: MPVRenderColorStatus) {
        self.options = options
        self.pixelFormat = pixelFormat
        self.status = status
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pixelFormat == rhs.pixelFormat && lhs.status == rhs.status
            && lhs.options.elementsEqual(rhs.options, by: { $0.0 == $1.0 && $0.1 == $1.1 })
    }
}
