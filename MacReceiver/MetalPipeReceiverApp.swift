//
//  MetalPipeReceiverApp.swift
//  MacReceiver
//
//  The window OBS captures. Keep it simple: video view + status bar.
//

import SwiftUI

@main
struct MetalPipeReceiverApp: App {
    @StateObject private var pipeline = ReceiverPipeline()

    var body: some Scene {
        WindowGroup("MetalPipe Receiver") {
            ContentView(pipeline: pipeline)
                .onAppear { pipeline.start() }
                .onDisappear { pipeline.stop() }
        }
    }
}

struct ContentView: View {
    @ObservedObject var pipeline: ReceiverPipeline

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            MetalVideoView(pipeline: pipeline)

            // Status overlay — auto-hides while streaming so OBS gets
            // a clean frame.
            if pipeline.statusText != "Streaming" {
                HStack(spacing: 8) {
                    Circle()
                        .fill(pipeline.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(pipeline.statusText)
                        .font(.system(.caption, design: .monospaced))
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(12)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}
