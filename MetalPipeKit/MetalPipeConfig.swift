//
//  MetalPipeConfig.swift
//  MetalPipeKit
//
//  Single source of truth for tunables. Shared by the broadcast
//  extension (iOS) and the receiver (macOS).
//

import Foundation

public enum MetalPipeConfig {

    /// Bonjour service the Mac advertises and the iPad browses for.
    /// Must match the NSBonjourServices entry in BOTH iOS Info.plists.
    public static let bonjourServiceType = "_metalpipe._tcp"

    // MARK: Encoding

    /// 12 Mbps is plenty for screen content at 30fps on LAN.
    /// Drop to 6_000_000 if you see Wi-Fi congestion.
    public static let targetBitrate = 12_000_000

    public static let expectedFPS = 30

    /// Keyframe every 2 seconds. Keyframes carry parameter sets,
    /// so a receiver that joins mid-stream recovers within 2s.
    public static let maxKeyframeIntervalFrames = 60

    // MARK: Backpressure (sender side)

    /// If more than this many bytes are queued in the socket,
    /// non-keyframes are dropped instead of buffered.
    /// This is the #1 defence against memory creep in the extension.
    public static let maxInFlightBytes = 3 * 1024 * 1024

    // MARK: Memory guard (extension side)

    /// ReplayKit upload extensions are jetsam-killed around ~50MB.
    /// We start shedding work well below that.
    public static let memorySoftLimitMB: Double = 35
    public static let memoryHardLimitMB: Double = 45

    // MARK: Liveness

    public static let heartbeatInterval: TimeInterval = 2
    /// Receiver resets the session if nothing arrives for this long.
    public static let watchdogTimeout: TimeInterval = 5
}
