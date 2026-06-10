//
//  VideoEncoder.swift
//  BroadcastExtension
//
//  Thin wrapper over VTCompressionSession. Rules that keep us alive
//  inside the 50MB extension memory budget:
//
//   1. No Metal, no pixel buffer copies. The IOSurface goes straight
//      from ReplayKit into the hardware encoder.
//   2. Realtime mode, no frame reordering (no B-frames).
//   3. Parameter sets re-sent on EVERY keyframe.
//
//  v1.1: rotation rides along with each frame. We deliberately do NOT
//  rotate pixels here — that would cost CPU/memory the extension
//  doesn't have. The Mac rotates for free in its shader.
//

import Foundation
import CoreMedia
import VideoToolbox

final class VideoEncoder {

    private var session: VTCompressionSession?
    private let onParameterSets: ([Data]) -> Void
    /// (avccData, ptsSeconds, isKeyframe, rotation)
    private let onEncodedFrame: (Data, Double, Bool, UInt8) -> Void

    private var forceKeyframeOnNext = false
    private let lock = NSLock()

    init?(width: Int32,
          height: Int32,
          onParameterSets: @escaping ([Data]) -> Void,
          onEncodedFrame: @escaping (Data, Double, Bool, UInt8) -> Void) {

        self.onParameterSets = onParameterSets
        self.onEncodedFrame = onEncodedFrame

        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &s)

        guard status == noErr, let session = s else { return nil }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: MetalPipeConfig.targetBitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: MetalPipeConfig.expectedFPS as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: MetalPipeConfig.maxKeyframeIntervalFrames as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func requestKeyframe() {
        lock.lock(); forceKeyframeOnNext = true; lock.unlock()
    }

    /// `rotation`: quarter-turns clockwise the receiver must apply (0...3).
    func encode(_ sampleBuffer: CMSampleBuffer, rotation: UInt8) {
        guard let session,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        var frameProperties: CFDictionary?
        lock.lock()
        if forceKeyframeOnNext {
            forceKeyframeOnNext = false
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
        }
        lock.unlock()

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: nil) { [weak self] status, _, encodedBuffer in
                guard status == noErr, let encodedBuffer, let self else { return }
                // `rotation` is captured per-frame by this closure.
                self.handleEncoded(encodedBuffer, rotation: rotation)
            }
    }

    private func handleEncoded(_ sb: CMSampleBuffer, rotation: UInt8) {
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
            as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        if isKeyframe, let fd = CMSampleBufferGetFormatDescription(sb) {
            let sets = Self.extractParameterSets(from: fd)
            if !sets.isEmpty { onParameterSets(sets) }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sb) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer,
                                              atOffset: 0,
                                              dataLength: length,
                                              destination: base)
        }
        guard copyStatus == noErr else { return }

        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        onEncodedFrame(data, pts, isKeyframe, rotation)
    }

    private static func extractParameterSets(from fd: CMFormatDescription) -> [Data] {
        var count = 0
        let probe = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fd, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        guard probe == noErr, count > 0 else { return [] }

        var sets: [Data] = []
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fd, parameterSetIndex: i,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if status == noErr, let pointer {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    deinit { invalidate() }
}

