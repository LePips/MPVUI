//
//  File.swift
//  
//
//  Created by Ethan Pippin on 5/14/24.
//

import MPVKit
import UIKit

public struct MPVMetalPlayer: _PlatformRepresentable {
    
    let client: MPVClient
    
    public init(client: MPVClient) {
        self.client = client
    }
    
    public func makeUIView(context: Context) -> MPVMetalView {
        let view = MPVMetalView(client: client)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .red.withAlphaComponent(0.2)
        return view
    }
    
    public func updateUIView(_ uiView: MPVMetalView, context: Context) {
        
    }
}

public class MPVMetalView: UIView {
    
    private let client: MPVClient
    private var metalLayer: CAMetalLayer = CAMetalLayer()
    
    static var logFile: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("mpvkit-mpv-log.txt")
    }
    
    public init(client: MPVClient) {
        self.client = client
        
        super.init(frame: .zero)
        
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.device = MTLCreateSystemDefaultDevice()!
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        
        if #available(iOS 16, *) {
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.edrMetadata = .hdr10(
                minLuminance: 0.5,
                maxLuminance: 1_000,
                opticalOutputScale: 100
            )
        }
        
//        try! client._set(property: "log-file", to: Self.logFile.absoluteString.replacingOccurrences(of: "file://", with: ""))
        
        mpv_set_option(client.core, "wid", MPV_FORMAT_INT64, &metalLayer)
//        
//        try! client._set(option: "auto-window-resize", to: "yes")
//        try! client._set(option: "keepaspect", to: "yes")
//        try! client._set(option: "autofit", to: "100%x100%")
        
        try! client._set(property: "target-colorspace-hint", to: true)
//        try! client._set(option: "hdr-compute-peak", to: "yes")
//        try! client._set(option: "target-prim", to: "bt.2020")
//        try! client._set(option: "target-trc", to: "pq")
//        try! client._set(option: "tone-mapping", to: "st2094-40")
//        try! client._set(option: "tone-mapping", to: "bt.2390")
        
        try! client._set(property: "vo", to: "gpu-next")
        try! client._set(property: "gpu-api", to: "vulkan")
        try! client._set(property: "gpu-context", to: "moltenvk")
        
        try! client._set(option: "hwdec", to: "videotoolbox")
        try! client._set(option: "hwdec-image-format", to: "nv12")
        try! client._set(option: "gpu-hwdec-interop", to: "auto")
        
        try! client._set(property: "cache-pause-initial", to: "yes")
        try! client._set(property: "cache-pause-wait", to: "3")
        try! client._set(property: "keep-open", to: "yes")
        try! client._set(property: "profile", to: "fast")
        
        layer.addSublayer(metalLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        
        metalLayer.frame = frame
        
        let primaries = client._getString(property: "video-params/primaries")
        let gamma = client._getString(property: "video-params/gamma")
        
        print(primaries)
        print(gamma)
    }
}
