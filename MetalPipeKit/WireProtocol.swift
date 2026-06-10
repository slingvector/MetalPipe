//
//  WireProtocol.swift
//  MetalPipeKit
//
//  Wire format (all integers big-endian):
//
//    ┌─────────┬──────┬──────────────┬─────────────┐
//    │ magic 4B│type1B│ payloadLen 4B│ payload ... │
//    └─────────┴──────┴──────────────┴─────────────┘
//
//  Design rule: every session is self-describing. Parameter sets are
//  re-sent with every keyframe, and `sessionStart` tells the receiver
//  to throw away ALL decoder state. Nothing survives a reconnect.
//

import Foundation

public enum WireProtocol {
    /// "MP2P"
    public static let magic: UInt32 = 0x4D50_3250
    public static let headerSize = 9
    /// Sanity cap — a single packet larger than this means desync.
    public static let maxPayloadSize: UInt32 = 32 * 1024 * 1024
}

public enum PacketType: UInt8 {
    /// Sender connected and is starting a fresh stream.
    /// Receiver MUST reset its decoder on this.
    case sessionStart  = 0x01
    /// H.264 SPS/PPS. Payload: count(1B) + [len(4B) + bytes] per set.
    case parameterSets = 0x02
    /// One encoded frame. Payload: pts(8B Double bitPattern) +
    /// flags(1B, bit0 = keyframe) + AVCC data.
    case videoFrame    = 0x03
    /// Keep-alive, empty payload.
    case heartbeat     = 0x04
}

// MARK: - Big-endian Data helpers

public extension Data {
    mutating func appendBE32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBE64(_ value: UInt64) {
        appendBE32(UInt32(truncatingIfNeeded: value >> 32))
        appendBE32(UInt32(truncatingIfNeeded: value))
    }

    /// Reads relative to startIndex — safe for Data slices.
    func be32(at offset: Int) -> UInt32? {
        guard count >= offset + 4 else { return nil }
        let i = startIndex + offset
        return (UInt32(self[i]) << 24)
             | (UInt32(self[i + 1]) << 16)
             | (UInt32(self[i + 2]) << 8)
             |  UInt32(self[i + 3])
    }

    func be64(at offset: Int) -> UInt64? {
        guard let hi = be32(at: offset), let lo = be32(at: offset + 4) else { return nil }
        return (UInt64(hi) << 32) | UInt64(lo)
    }

    func byte(at offset: Int) -> UInt8? {
        guard count > offset else { return nil }
        return self[startIndex + offset]
    }
}
