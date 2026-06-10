//
//  VideoRenderer.swift
//  MacReceiver
//
//  Renders NV12 CVPixelBuffers into an MTKView with zero copies:
//  CVMetalTextureCache maps the decoder's IOSurface planes directly
//  to Metal textures, and a tiny fragment shader does BT.709 YUV→RGB.
//  This window is what OBS captures.
//

import SwiftUI
import MetalKit
import CoreVideo

// MARK: - SwiftUI wrapper

struct MetalVideoView: NSViewRepresentable {
    let pipeline: ReceiverPipeline

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true                 // we drive draws ourselves
        view.enableSetNeedsDisplay = true

        let renderer = VideoRenderer(view: view)
        view.delegate = renderer
        context.coordinator.renderer = renderer

        pipeline.onFrame = { [weak renderer, weak view] pixelBuffer in
            renderer?.latestFrame = pixelBuffer
            DispatchQueue.main.async { view?.needsDisplay = true }
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Coordinator {
        var renderer: VideoRenderer?
    }
}

// MARK: - Renderer

final class VideoRenderer: NSObject, MTKViewDelegate {

    /// Most recent decoded frame. Written by the decoder thread,
    /// read in draw(in:). A lock keeps the handoff clean; we only
    /// ever keep ONE frame alive.
    var latestFrame: CVPixelBuffer? {
        get { lock.lock(); defer { lock.unlock() }; return _latestFrame }
        set { lock.lock(); _latestFrame = newValue; lock.unlock() }
    }
    private var _latestFrame: CVPixelBuffer?
    private let lock = NSLock()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?

    init(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else {
            fatalError("Metal unavailable")
        }
        self.device = device
        self.commandQueue = queue
        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        buildPipeline(view: view)
    }

    private func buildPipeline(view: MTKView) {
        guard let library = device.makeDefaultLibrary() else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "nv12Fragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pixelBuffer = latestFrame,
              let pipelineState,
              let textureCache,
              let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        guard let yTexture = makeTexture(pixelBuffer, cache: textureCache,
                                         plane: 0, format: .r8Unorm),
              let cbcrTexture = makeTexture(pixelBuffer, cache: textureCache,
                                            plane: 1, format: .rg8Unorm) else { return }

        // Aspect-fit scale: shrink the quad on one axis so the video
        // letterboxes instead of stretching.
        let videoAspect = Float(CVPixelBufferGetWidth(pixelBuffer))
                        / Float(CVPixelBufferGetHeight(pixelBuffer))
        let drawableAspect = Float(view.drawableSize.width)
                           / Float(view.drawableSize.height)
        var scale = SIMD2<Float>(1, 1)
        if videoAspect > drawableAspect {
            scale.y = drawableAspect / videoAspect
        } else {
            scale.x = videoAspect / drawableAspect
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
        else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(cbcrTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer,
                             cache: CVMetalTextureCache,
                             plane: Int,
                             format: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            format, width, height, plane, &cvTexture)

        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }
}
