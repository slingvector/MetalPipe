//
//  StreamSender.swift
//  BroadcastExtension
//
//  Finds the Mac via Bonjour, connects over TCP, and sends packets
//  with strict backpressure: if the socket can't keep up we DROP
//  non-keyframes instead of queueing them. Unbounded send queues are
//  exactly how the old project ate its 50MB budget and got jetsammed.
//
//  Network.framework handles socket cleanup on cancel, so a killed or
//  finished session can never leave a stale port behind.
//

import Foundation
import Network

final class StreamSender {

    enum State { case searching, connecting, ready, stopped }

    private let queue = DispatchQueue(label: "metalpipe.sender")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var heartbeat: DispatchSourceTimer?

    /// Bytes handed to NWConnection but not yet processed.
    private var inFlightBytes = 0
    private(set) var droppedFrames = 0

    private var _state: State = .stopped
    private let stateLock = NSLock()
    var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }
    private func setState(_ s: State) {
        stateLock.lock(); _state = s; stateLock.unlock()
        if s == .ready { onReady?() }
    }

    /// Fired (on the sender queue) whenever the connection becomes
    /// ready — used to force a keyframe and send sessionStart.
    var onReady: (() -> Void)?

    // MARK: Lifecycle

    func start() {
        queue.async { [weak self] in self?.startBrowsing() }
    }

    private func startBrowsing() {
        setState(.searching)
        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: MetalPipeConfig.bonjourServiceType, domain: nil),
            using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil,
                  let first = results.first else { return }
            self.connect(to: first.endpoint)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func connect(to endpoint: NWEndpoint) {
        setState(.connecting)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true                    // latency over throughput
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true

        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.inFlightBytes = 0
                self.setState(.ready)
                self.sendNow(Packetizer.packet(type: .sessionStart))
                self.startHeartbeat()
            case .failed, .cancelled:
                self.heartbeat?.cancel()
                self.heartbeat = nil
                self.connection = nil
                // Go back to browsing — the Mac app may have restarted.
                if self.state != .stopped { self.startBrowsing() }
            default:
                break
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setState(.stopped)
            self.heartbeat?.cancel()
            self.heartbeat = nil
            self.browser?.cancel()
            self.browser = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    // MARK: Sending

    /// `droppable: true` for delta frames, `false` for keyframes,
    /// parameter sets and control packets.
    func send(_ packet: Data, droppable: Bool) {
        queue.async { [weak self] in
            guard let self, self.state == .ready else { return }
            if droppable && self.inFlightBytes > MetalPipeConfig.maxInFlightBytes {
                self.droppedFrames += 1
                return
            }
            self.sendNow(packet)
        }
    }

    /// Must be called on `queue`.
    private func sendNow(_ packet: Data) {
        guard let connection else { return }
        inFlightBytes += packet.count
        let size = packet.count
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
            // Completion runs on `queue` (connection started there).
            self?.inFlightBytes -= size
        })
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + MetalPipeConfig.heartbeatInterval,
                       repeating: MetalPipeConfig.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.sendNow(Packetizer.packet(type: .heartbeat))
        }
        timer.resume()
        heartbeat = timer
    }
}
