//
//  SampleHandler.swift
//  BroadcastExtension
//
//  The ReplayKit entry point. Total responsibilities:
//
//    sample buffer in → hardware encode → packetize → socket out
//
//  Everything else (Metal, preview, UI) lives on the Mac. The rules:
//
//   - processSampleBuffer returns FAST. No queues of raw frames, ever.
//     One retained iPad frame ≈ 6MB IOSurface; four of them is 25% of
//     our entire memory budget.
//   - Frames are dropped (not buffered) when the network or memory
//     can't keep up.
//   - broadcastFinished tears down EVERYTHING. Combined with the
//     receiver's sessionStart reset, no state survives between runs.
//

import ReplayKit
import CoreMedia

class SampleHandler: RPBroadcastSampleHandler {

    private let sender = StreamSender()
    private var encoder: VideoEncoder?
    private var frameCounter = 0
    private var shedDeltaFrames = false   // set under memory pressure

    // MARK: Broadcast lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        sender.onReady = { [weak self] in
            // Fresh connection: receiver has no decoder state yet,
            // so the very next frame must be a keyframe.
            self?.encoder?.requestKeyframe()
        }
        sender.start()
    }

    override func broadcastPaused() { /* nothing buffered, nothing to do */ }

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
        guard sampleBufferType == .video else { return } // audio: out of scope for v1

        autoreleasepool {
            // Don't even encode if nobody is listening — keeps the
            // extension near-idle while the Mac app isn't running.
            guard sender.state == .ready else { return }

            if encoder == nil {
                createEncoder(from: sampleBuffer)
            }

            frameCounter += 1

            // Memory check every ~2 seconds of video.
            if frameCounter % 60 == 0 {
                switch MemoryGuard.pressure() {
                case .ok:
                    shedDeltaFrames = false
                case .soft:
                    // Degrade gracefully: halve the frame rate.
                    shedDeltaFrames = true
                case .hard:
                    // Better to end cleanly than be jetsam-killed with
                    // no explanation (the old "got stuck" failure).
                    let error = NSError(
                        domain: "MetalPipe", code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "MetalPipe stopped: extension memory limit reached."])
                    finishBroadcastWithError(error)
                    return
                }
            }

            if shedDeltaFrames && frameCounter % 2 == 0 { return }

            encoder?.encode(sampleBuffer)
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
            onEncodedFrame: { [weak self] data, pts, isKeyframe in
                let payload = Packetizer.framePayload(pts: pts,
                                                      isKeyframe: isKeyframe,
                                                      avccData: data)
                self?.sender.send(Packetizer.packet(type: .videoFrame, payload: payload),
                                  droppable: !isKeyframe)
            })

        encoder?.requestKeyframe()
    }
}
