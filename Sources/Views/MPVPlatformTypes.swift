import MPVCore
#if canImport(UIKit)
import SwiftUI
import UIKit

typealias PlatformColor = UIColor
/// The UIKit view type used by the video surface.
public typealias MPVPlatformView = UIView
typealias PlatformViewRepresentable = UIViewRepresentable
typealias PlatformWindow = UIWindow
#elseif canImport(AppKit)
import AppKit
import SwiftUI

typealias PlatformColor = NSColor
/// The AppKit view type used by the video surface.
public typealias MPVPlatformView = NSView
typealias PlatformViewRepresentable = NSViewRepresentable
typealias PlatformWindow = NSWindow
#endif
