#if canImport(UIKit)
import SwiftUI
import UIKit

typealias PlatformColor = UIColor
public typealias PlatformView = UIView
typealias PlatformViewRepresentable = UIViewRepresentable
typealias PlatformWindow = UIWindow
#elseif canImport(AppKit)
import AppKit
import SwiftUI

typealias PlatformColor = NSColor
public typealias PlatformView = NSView
typealias PlatformViewRepresentable = NSViewRepresentable
typealias PlatformWindow = NSWindow
#endif
