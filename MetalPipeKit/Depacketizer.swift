//
//  Depacketizer.swift
//  MetalPipeKit
//
//  Reassembles a TCP byte stream into (type, payload) packets.
//  If the magic ever mismatches we are desynced; we drop the buffer
//  and wait — the next keyframe (≤2s away) restores the picture.
//  Cheap, simple recovery beats clever resync logic.
//

import Foundation

public final class Depacketizer {

    private var buffer = Data()

    public init() {}

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Feed raw bytes, get back zero or more complete packets.
    public func append(_ data: Data) -> [(type: PacketType, payload: Data)] {
        buffer.append(data)
        var packets: [(PacketType, Data)] = []

        while buffer.count >= WireProtocol.headerSize {
            guard let magic = buffer.be32(at: 0), magic == WireProtocol.magic else {
                // Desync — drop everything and resync on next data.
                buffer.removeAll(keepingCapacity: true)
                break
            }

            guard let typeByte = buffer.byte(at: 4),
                  let payloadLen32 = buffer.be32(at: 5),
                  payloadLen32 <= WireProtocol.maxPayloadSize else {
                buffer.removeAll(keepingCapacity: true)
                break
            }

            let payloadLen = Int(payloadLen32)
            let total = WireProtocol.headerSize + payloadLen
            guard buffer.count >= total else { break } // wait for more bytes

            if let type = PacketType(rawValue: typeByte) {
                let start = buffer.startIndex + WireProtocol.headerSize
                packets.append((type, Data(buffer[start ..< start + payloadLen])))
            }
            // else: unknown type — skip it silently (forward compat)

            buffer = Data(buffer.dropFirst(total))
        }
        return packets
    }
}
