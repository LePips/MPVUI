//
//  File.swift
//  
//
//  Created by Ethan Pippin on 4/17/24.
//

import Foundation
import GLKit
import MPVKit
import SwiftUI

public struct MPVPlayer: _PlatformRepresentable {
    
    let client: MPVClient
    
    public init(client: MPVClient) {
        self.client = client
    }
    
    public func makeUIView(context: Context) -> MPVOGLView {
        let view = MPVOGLView()
        view.translatesAutoresizingMaskIntoConstraints = false
        client.attach(to: view)
        return view
    }
    
    public func updateUIView(_ uiView: MPVOGLView, context: Context) {
        
    }
}

// GLKView
public final class MPVOGLView: GLKView, DrawableView {
    
    private var defaultFBO: GLint?

    var canvas: OpaquePointer!
    var renderQueue = DispatchQueue(label: "mpvui.opengl")
    var needsDrawing = true
    
    init() {
        super.init(frame: .zero)
        
        guard let context = EAGLContext(api: .openGLES2) else {
            print("Failed to initialize OpenGLES 2.0 context")
            exit(1)
        }
         
        self.context = context
        bindDrawable()

        defaultFBO = -1
        enableSetNeedsDisplay = false
        
        print(self.layer)
        
        if #available(iOS 17.0, *) {
            let layer = self.layer as! CAEAGLLayer
            
            layer.wantsExtendedDynamicRangeContent = true
        }
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    override public func draw(_ a: CGRect) {
        guard needsDrawing, let canvas else {
            return
        }

        glGetIntegerv(UInt32(GL_FRAMEBUFFER_BINDING), &defaultFBO!)

        var dims: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)

        var flip: CInt = 1
        var data = mpv_opengl_fbo(
            fbo: Int32(defaultFBO!),
            w: Int32(dims[2]),
            h: Int32(dims[3]),
            internal_format: 0
        )
        
        withUnsafeMutablePointer(to: &flip) { flip in
            withUnsafeMutablePointer(to: &data) { data in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: data),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flip),
                    mpv_render_param()
                ]
                mpv_render_context_render(canvas, &params)
            }
        }
    }
    
    public override func display() {
        super.display()
        
        CATransaction.flush()
    }
}
