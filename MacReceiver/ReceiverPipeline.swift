//
//  ReceiverPipeline.swift
//  MacReceiver
//
//  v1.1: frame callback now includes display rotation.
//

import Foundation
import CoreVideo
import Combine

final class ReceiverPipeline: ObservableObject {

    @Published var isConnected = false
    @Published var statusText = "Waiting for iPad…"
    @Published var fps = 0

    /// (pixelBuffer, rotation) — rotation is quarter-turns clockwise.
    var onFrame: ((CVPixelBuffer, UInt8) -> Void)?

    private let listener = StreamListener()
    private let decoder = VideoDecoder()

    private var lastPacketDate = Date.distantPast
    private var watchdog: Timer?
    private var frameCountThisSecond = 0
    private var fpsWindowStart = Date()

    func start() {
        decoder.onFrame = { [weak self] pixelBuffer, rotation in
            guard let self else { return }
            self.onFrame?(pixelBuffer, rotation)
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
                self.listener.dropConnection()
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
