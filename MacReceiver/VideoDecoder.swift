//
//  VideoDecoder.swift
//  MacReceiver
//
//  VTDecompressionSession wrapper with one core policy:
//
//      New parameter sets that the current session can't accept
//      ⇒ tear the session down and build a fresh one.
//
//  This is the fix for the classic "second broadcast session shows a
//  frozen/black picture" bug: the old session was still configured
//  for the previous stream's format and silently rejected frames.
//

import Foundation
import CoreMedia
import VideoToolbox

final class VideoDecoder {

    /// Decoded frames, delivered on the decoder's callback thread.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var hasSeenKeyframe = false

    // MARK: Session control

    /// Called on `sessionStart` and on watchdog reset.
    /// After this, nothing decodes until new parameter sets arrive.
    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = nil
        hasSeenKeyframe = false
    }

    func updateParameterSets(_ sets: [Data]) {
        guard sets.count >= 2,
              let newFD = Self.makeFormatDescription(sets: sets) else { return }

        // Same format and a live session that accepts it? Keep going.
        if let session, let oldFD = formatDescription,
           CMFormatDescriptionEqual(newFD, otherFormatDescription: oldFD),
           VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFD) {
            return
        }

        // Anything else: rebuild from scratch.
        reset()
        formatDescription = newFD

        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFD,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession)

        guard status == noErr else { return }
        session = newSession
    }

    // MARK: Decoding

    func decode(_ frame: Packetizer.Frame) {
        guard let session, let formatDescription else { return }

        // Never feed delta frames before the first keyframe of a
        // (re)started session — decoders hate that.
        if !hasSeenKeyframe {
            guard frame.isKeyframe else { return }
            hasSeenKeyframe = true
        }

        guard let sampleBuffer = Self.makeSampleBuffer(
            avccData: frame.avccData,
            pts: frame.pts,
            formatDescription: formatDescription) else { return }

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: flags,
            infoFlagsOut: nil) { [weak self] status, _, imageBuffer, _, _ in
                if status == kVTInvalidSessionErr {
                    // e.g. Mac slept and woke. Rebuild on next keyframe.
                    self?.reset()
                    return
                }
                guard status == noErr, let pixelBuffer = imageBuffer else { return }
                self?.onFrame?(pixelBuffer)
            }
    }

    // MARK: Construction helpers

    private static func makeFormatDescription(sets: [Data]) -> CMVideoFormatDescription? {
        // Copy each set into stable heap memory for the C call.
        let buffers: [UnsafeMutablePointer<UInt8>] = sets.map { data in
            let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: ptr, count: data.count)
            return ptr
        }
        defer { buffers.forEach { $0.deallocate() } }

        var pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        var sizes: [Int] = sets.map { $0.count }

        var fd: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: pointers.count,
            parameterSetPointers: &pointers,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: 4,        // AVCC with 4-byte length prefixes
            formatDescriptionOut: &fd)

        return status == noErr ? fd : nil
    }

    private static func makeSampleBuffer(avccData: Data,
                                         pts: Double,
                                         formatDescription: CMVideoFormatDescription)
        -> CMSampleBuffer? {

        var blockBuffer: CMBlockBuffer?
        let length = avccData.count

        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer) == noErr,
            let bb = blockBuffer else { return nil }

        let copyStatus = avccData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: bb,
                offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000),
            decodeTimeStamp: .invalid)
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?

        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr else { return nil }

        return sampleBuffer
    }

    deinit { reset() }
}
