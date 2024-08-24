//
//  File.swift
//  
//
//  Created by Ethan Pippin on 4/17/24.
//

import Foundation
import MPVKit

#if os(iOS)
import UIKit
#else
import AppKit
#endif

protocol DrawableView: UIView {
    
    var canvas: OpaquePointer! { get set }
}

extension MPVClient {
    
    func attach<V: DrawableView>(to view: V) {
        
        let openGLAPI = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
        var initParams = mpv_opengl_init_params(
            get_proc_address: openGLAddress,
            get_proc_address_ctx: nil
        )

        withUnsafeMutablePointer(to: &initParams) { initParams in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: openGLAPI),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initParams),
                mpv_render_param()
            ]

            if mpv_render_context_create(
                &view.canvas,
                core,
                &params
            ) < 0 {
                print("failed to initialize mpv GL context")
                exit(1)
            }

            mpv_render_context_set_update_callback(
                view.canvas,
                glUpdate(_:),
                UnsafeMutableRawPointer(Unmanaged.passUnretained(view).toOpaque())
            )
        }
    }
}

private func openGLAddress(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<Int8>?) -> UnsafeMutableRawPointer? {
    
    let symbolName = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
    let identifier = CFBundleGetBundleWithIdentifier("com.apple.opengles" as CFString)

    return CFBundleGetFunctionPointerForName(identifier, symbolName)
}

private func glUpdate(_ ctx: UnsafeMutableRawPointer?) {
    
    let glView = unsafeBitCast(ctx, to: MPVOGLView.self)

    guard glView.needsDrawing else { return }

    glView.renderQueue.async {
        glView.display()
    }
}
