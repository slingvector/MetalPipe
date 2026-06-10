//
//  Packetizer.swift
//  MetalPipeKit
//
//  Builds outgoing packets (sender) and parses payloads (receiver).
//  Pure functions, no state, trivially testable.
//
//  v1.1: frame flags byte now carries display rotation in bits 1-2:
//        bit 0      = keyframe
//        bits 1-2   = rotation (0 = 0°, 1 = 90° CW, 2 = 180°, 3 = 270° CW)
//

import Foundation

public enum Packetizer {

    // MARK: Building (sender side)

    public static func packet(type: PacketType, payload: Data = Data()) -> Data {
        var d = Data(capacity: WireProtocol.headerSize + payload.count)
        d.appendBE32(WireProtocol.magic)
        d.append(type.rawValue)
        d.appendBE32(UInt32(payload.count))
        d.append(payload)
        return d
    }

    public static func parameterSetsPayload(_ sets: [Data]) -> Data {
        var d = Data()
        d.append(UInt8(sets.count))
        for set in sets {
            d.appendBE32(UInt32(set.count))
            d.append(set)
        }
        return d
    }

    public static func framePayload(pts: Double,
                                    isKeyframe: Bool,
                                    rotation: UInt8,
                                    avccData: Data) -> Data {
        var flags: UInt8 = isKeyframe ? 0x01 : 0x00
        flags |= (rotation & 0x03) << 1
        var d = Data(capacity: 9 + avccData.count)
        d.appendBE64(pts.bitPattern)
        d.append(flags)
        d.append(avccData)
        return d
    }

    // MARK: Parsing (receiver side)

    public static func parseParameterSets(_ payload: Data) -> [Data]? {
        guard let count = payload.byte(at: 0) else { return nil }
        var sets: [Data] = []
        var offset = 1
        for _ in 0..<count {
            guard let len32 = payload.be32(at: offset) else { return nil }
            let len = Int(len32)
            offset += 4
            guard payload.count >= offset + len else { return nil }
            let start = payload.startIndex + offset
            sets.append(Data(payload[start ..< start + len]))
            offset += len
        }
        return sets
    }

    public struct Frame {
        public let pts: Double
        public let isKeyframe: Bool
        /// Quarter-turns clockwise the receiver must apply: 0...3
        public let rotation: UInt8
        public let avccData: Data
    }

    public static func parseFrame(_ payload: Data) -> Frame? {
        guard let bits = payload.be64(at: 0),
              let flags = payload.byte(at: 8),
              payload.count > 9 else { return nil }
        let start = payload.startIndex + 9
        return Frame(pts: Double(bitPattern: bits),
                     isKeyframe: flags & 0x01 != 0,
                     rotation: (flags >> 1) & 0x03,
                     avccData: Data(payload[start...]))
    }
}
