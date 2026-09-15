#if canImport(UIKit)
import SwiftUI
import UIKit

typealias PlatformColor = UIColor
/// The UIKit view type used by the video surface.
public typealias PlatformView = UIView
typealias PlatformViewRepresentable = UIViewRepresentable
typealias PlatformWindow = UIWindow
#elseif canImport(AppKit)
import AppKit
import SwiftUI

typealias PlatformColor = NSColor
/// The AppKit view type used by the video surface.
public typealias PlatformView = NSView
typealias PlatformViewRepresentable = NSViewRepresentable
typealias PlatformWindow = NSWindow
#endif
