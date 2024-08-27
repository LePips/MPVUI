//
//  ContentView.swift
//  MPVUI-Example
//
//  Created by Ethan Pippin on 4/9/24.
//

import Combine
import MPVUI
import MPVKit
import SwiftUI

class ViewModel: ObservableObject {
    
    @Published
    var cacheProgress: Double = 0
    
    let client = MPVClient()
    
    private var loaded = false
    
    init() {
        
        Task {
            for await event in client.events.values {
//                print(event)
            }
        }
        
        Task {
            for await _ in try! client._observe(property: "time-pos", format: MPV_FORMAT_DOUBLE).values {
//                getTime()
            }
        }
    }
    
    private func getTime() {
        DispatchQueue.main.async {
            print(self.client._getDouble(property: "time-pos"))
        }
    }
    
    func play() {
        if !loaded {
            
            client.logLevel = .debug
            
//            try! client._command(.loadfile, arguments: "https://freetestdata.com/wp-content/uploads/2021/09/Free_Test_Data_1OMB_MP3.mp3", "replace")
//            try! client._command(.loadfile, arguments: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4", "replace")
            try! client._command(.loadfile, arguments: "https://static.videezy.com/system/protected/files/000/021/518/Flying_Over_Cliff_4K.mp4", "replace")
            
//            try! client._command(.loadfile, arguments: "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8", "replace")
            
            loaded = true
            
        } else {
            client.play()
        }
    }
    
    func pause() {
        client.pause()
    }
    
    func getProgress() {
        
        let cacheDuration = client._getDouble(property: "demuxer-cache-duration")
        let totalDuration = client._getDouble(property: "duration")
        cacheProgress = cacheDuration / totalDuration
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            self.getProgress()
        }
    }
}

struct ContentView: View {
    
    @State
    private var playerFrame: CGRect = .zero
    
    @State
    private var otherHeight: CGFloat = 0.0
    
    @StateObject
    private var viewModel = ViewModel()
    
    var body: some View {
        ZStack(alignment: .bottom) {
            
            VStack(spacing: 0) {
//                MPVPlayer(client: viewModel.client)
                MPVMetalPlayer(client: viewModel.client)
                
//                Color.red
//                    .frame(height: otherHeight)
            }
            
            HStack {
                Button {
                    viewModel.play()
                } label: {
                    Text("Play")
                        .padding(10)
                        .background {
                            Color.blue
                                .opacity(0.6)
                        }
                }
                
                Button {
                    viewModel.pause()
                } label: {
                    Text("Pause")
                        .padding(10)
                        .background {
                            Color.blue
                                .opacity(0.6)
                        }
                }
                
                Text("\(viewModel.cacheProgress)")
                    .monospacedDigit()
                
                Slider(value: $otherHeight, in: 1 ... 20, step: 0.2)
            }
            .padding(10)
        }
        .animation(.linear(duration: 0.3), value: otherHeight)
        .ignoresSafeArea()
        .onAppear {
            viewModel.getProgress()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.viewModel.play()
            }
        }
        .onChange(of: otherHeight) { oldValue, newValue in
            try! viewModel.client._set(property: "sub-scale", to: newValue)
        }
    }
}

struct FramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {}
}

extension View {
    
    func onFrameChanged(_ onChange: @escaping (CGRect) -> Void) -> some View {
        background {
            GeometryReader { reader in
                Color.clear
                    .preference(key: FramePreferenceKey.self, value: reader.frame(in: .global))
            }
        }
        .onPreferenceChange(FramePreferenceKey.self, perform: onChange)
    }

    // TODO: probably rename since this doesn't set the frame but tracks it
    func frame(_ binding: Binding<CGRect>) -> some View {
        onFrameChanged { newFrame in
            binding.wrappedValue = newFrame
        }
    }
}
