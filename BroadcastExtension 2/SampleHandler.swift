//
//  SampleHandler.swift
//  BroadcastExtension
//
//  v1.1: reads RPVideoSampleOrientationKey from each sample buffer.
//  ReplayKit does NOT rotate pixels when the iPad rotates — it keeps
//  the buffer in a fixed orientation and tags each frame with how it
//  should be displayed. We forward that tag to the Mac, which rotates
//  on the GPU for free.
//

import ReplayKit
import CoreMedia
import ImageIO

class SampleHandler: RPBroadcastSampleHandler {

    private let sender = StreamSender()
    private var encoder: VideoEncoder?
    private var frameCounter = 0
    private var shedDeltaFrames = false

    // MARK: Broadcast lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        sender.onReady = { [weak self] in
            self?.encoder?.requestKeyframe()
        }
        sender.start()
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {
        encoder?.requestKeyframe()
    }

    override func broadcastFinished() {
        encoder?.invalidate()
        encoder = nil
        sender.stop()
    }

    // MARK: Samples

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        autoreleasepool {
            guard sender.state == .ready else { return }

            if encoder == nil {
                createEncoder(from: sampleBuffer)
            }

            frameCounter += 1

            if frameCounter % 60 == 0 {
                switch MemoryGuard.pressure() {
                case .ok:
                    shedDeltaFrames = false
                case .soft:
                    shedDeltaFrames = true
                case .hard:
                    let error = NSError(
                        domain: "MetalPipe", code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "MetalPipe stopped: extension memory limit reached."])
                    finishBroadcastWithError(error)
                    return
                }
            }

            if shedDeltaFrames && frameCounter % 2 == 0 { return }

            encoder?.encode(sampleBuffer, rotation: Self.rotation(of: sampleBuffer))
        }
    }

    // MARK: Orientation

    /// Maps ReplayKit's per-frame orientation tag to the number of
    /// 90° clockwise turns the receiver must apply.
    ///
    /// NOTE: if you ever see the image rotated the WRONG way (90° off
    /// in the opposite direction), swap the return values for the
    /// .left and .right cases — the EXIF conventions here are the
    /// single most commonly inverted thing in all of iOS development.
    private static func rotation(of sampleBuffer: CMSampleBuffer) -> UInt8 {
        guard let attachment = CMGetAttachment(
                sampleBuffer,
                key: RPVideoSampleOrientationKey as CFString,
                attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: attachment.uint32Value)
        else { return 0 }

        switch orientation {
        case .up, .upMirrored:       return 0
        case .right, .rightMirrored: return 3   // needs 270° CW (90° CCW)
        case .down, .downMirrored:   return 2   // needs 180°
        case .left, .leftMirrored:   return 1   // needs 90° CW
        @unknown default:            return 0
        }
    }

    // MARK: Setup

    private func createEncoder(from sampleBuffer: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)

        encoder = VideoEncoder(
            width: dims.width,
            height: dims.height,
            onParameterSets: { [weak self] sets in
                let payload = Packetizer.parameterSetsPayload(sets)
                self?.sender.send(Packetizer.packet(type: .parameterSets, payload: payload),
                                  droppable: false)
            },
            onEncodedFrame: { [weak self] data, pts, isKeyframe, rotation in
                let payload = Packetizer.framePayload(pts: pts,
                                                      isKeyframe: isKeyframe,
                                                      rotation: rotation,
                                                      avccData: data)
                self?.sender.send(Packetizer.packet(type: .videoFrame, payload: payload),
                                  droppable: !isKeyframe)
            })

        encoder?.requestKeyframe()
    }
}
