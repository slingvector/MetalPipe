//
//  StreamListener.swift
//  MacReceiver
//
//  Advertises _metalpipe._tcp via Bonjour and accepts ONE connection
//  at a time. A new incoming connection always replaces the old one —
//  this is what makes "stop broadcast, start broadcast" on the iPad
//  Just Work even if the old TCP connection hasn't timed out yet.
//

import Foundation
import Network

final class StreamListener {

    /// Delivered on the listener queue.
    var onPacket: ((PacketType, Data) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "metalpipe.listener")
    private var listener: NWListener?
    private var connection: NWConnection?
    private let depacketizer = Depacketizer()

    func start() {
        queue.async { [weak self] in self?.startListener() }
    }

    private func startListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true

        guard let listener = try? NWListener(using: params) else { return }

        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "MetalPipe Receiver",
            type: MetalPipeConfig.bonjourServiceType)

        listener.newConnectionHandler = { [weak self] conn in
            self?.adopt(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            // If the listener dies (e.g. network interface change),
            // restart it after a beat.
            if case .failed = state {
                self?.queue.asyncAfter(deadline: .now() + 1) {
                    self?.startListener()
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// New connection replaces old — single-sender policy.
    private func adopt(_ conn: NWConnection) {
        connection?.cancel()
        depacketizer.reset()
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onConnectionChange?(true)
            case .failed, .cancelled:
                if self?.connection === conn {
                    self?.connection = nil
                    self?.onConnectionChange?(false)
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        receiveLoop(conn)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1,
                     maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                for (type, payload) in self.depacketizer.append(data) {
                    self.onPacket?(type, payload)
                }
            }

            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receiveLoop(conn)
        }
    }

    /// Called by the watchdog when the sender has gone silent.
    func dropConnection() {
        queue.async { [weak self] in
            self?.connection?.cancel()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
            self?.listener?.cancel()
            self?.listener = nil
        }
    }
}
