//
//  ReceiverPipeline.swift
//  MacReceiver
//
//  Wires listener → depacketized packets → decoder → renderer, and
//  owns the watchdog: if the sender goes silent (iPad locked, Wi-Fi
//  drop, extension killed), we cancel the connection and reset the
//  decoder so the NEXT session starts perfectly clean. The old
//  project's "worked a few times then stuck" pattern is exactly what
//  happens when this reset path doesn't exist.
//

import Foundation
import CoreVideo
import Combine

final class ReceiverPipeline: ObservableObject {

    @Published var isConnected = false
    @Published var statusText = "Waiting for iPad…"
    @Published var fps = 0

    /// Latest decoded frame for the renderer. Set on a background
    /// thread; the renderer reads it on the main/draw thread.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let listener = StreamListener()
    private let decoder = VideoDecoder()

    private var lastPacketDate = Date.distantPast
    private var watchdog: Timer?
    private var frameCountThisSecond = 0
    private var fpsWindowStart = Date()

    func start() {
        decoder.onFrame = { [weak self] pixelBuffer in
            guard let self else { return }
            self.onFrame?(pixelBuffer)
            self.tickFPS()
        }

        listener.onPacket = { [weak self] type, payload in
            self?.handle(type: type, payload: payload)
        }

        listener.onConnectionChange = { [weak self] connected in
            DispatchQueue.main.async {
                self?.isConnected = connected
                self?.statusText = connected ? "Connected — waiting for video…"
                                             : "Waiting for iPad…"
                if !connected { self?.decoder.reset() }
            }
        }

        listener.start()
        startWatchdog()
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        listener.stop()
        decoder.reset()
    }

    // MARK: Packet routing

    private func handle(type: PacketType, payload: Data) {
        lastPacketDate = Date()

        switch type {
        case .sessionStart:
            // Fresh broadcast session: forget everything.
            decoder.reset()

        case .parameterSets:
            if let sets = Packetizer.parseParameterSets(payload) {
                decoder.updateParameterSets(sets)
            }

        case .videoFrame:
            if let frame = Packetizer.parseFrame(payload) {
                decoder.decode(frame)
            }

        case .heartbeat:
            break
        }
    }

    // MARK: Watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isConnected else { return }
            if Date().timeIntervalSince(self.lastPacketDate) > MetalPipeConfig.watchdogTimeout {
                self.statusText = "Sender silent — resetting…"
                self.listener.dropConnection()   // triggers onConnectionChange(false)
            }
        }
    }

    // MARK: FPS counter

    private func tickFPS() {
        frameCountThisSecond += 1
        let now = Date()
        if now.timeIntervalSince(fpsWindowStart) >= 1 {
            let measured = frameCountThisSecond
            frameCountThisSecond = 0
            fpsWindowStart = now
            DispatchQueue.main.async {
                self.fps = measured
                if self.isConnected { self.statusText = "Streaming" }
            }
        }
    }
}
