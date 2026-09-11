import AppKit
@preconcurrency import MetalKit
@preconcurrency import CoreVideo

// Adapted from Mac Duo (MIT); see THIRD_PARTY_NOTICES.md.
struct LidFoldUniforms {
    var progress: Float = 0
    var perspective: Float = 0.7
    var blur: Float = 0.65
    var shadow: Float = 0.65
    var size = SIMD2<Float>(1, 1)
}

enum LidFoldError: LocalizedError {
    case message(String)
    case displayUnavailable
    var errorDescription: String? {
        if case let .message(message) = self { return message }
        return "内建屏幕正在恢复。"
    }
}

@MainActor
final class LidFoldRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private var blurPyramid: MTLTexture?
    private var blurLevels: [MTLTexture] = []
    private var blurredRevision: UInt64?
    private var generation = 0
    private var cache: CVMetalTextureCache?
    private let inFlight = DispatchSemaphore(value: 2)
    var frame: LidFoldFrame?
    var uniforms = LidFoldUniforms()
    var onFailure: (() -> Void)?
    var onPresented: (() -> Void)?

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw LidFoldError.message("无法创建图形渲染队列。")
        }
        self.queue = queue
        let library = try device.makeLibrary(source: LidFoldShader.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "foldVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "foldFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let function = library.makeFunction(name: "foldDownsample") else {
            throw LidFoldError.message("无法创建翻盖模糊效果。")
        }
        downsamplePipeline = try device.makeComputePipelineState(function: function)
        super.init()
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw LidFoldError.message("无法创建桌面画面缓存。")
        }
    }

    func clearFrame() {
        generation += 1
        frame = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let frame, let cache, inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }
        var wrapped: CVMetalTexture?
        let buffer = frame.buffer
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &wrapped
        )
        guard result == kCVReturnSuccess, let wrapped,
              let texture = CVMetalTextureGetTexture(wrapped),
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        uniforms.size = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        do {
            try encode(command: command, pass: pass, texture: texture,
                       uniforms: uniforms, sourceRevision: frame.revision)
        } catch {
            onFailure?()
            return
        }
        let token = generation
        let resources = LidFoldGPUResources(frame: frame, texture: wrapped)
        command.addCompletedHandler { [weak self, inFlight, resources] command in
            withExtendedLifetime(resources) {}
            inFlight.signal()
            let succeeded = command.status == .completed
            Task { @MainActor [weak self] in
                guard let self, generation == token else { return }
                if succeeded { onPresented?() } else { onFailure?() }
            }
        }
        command.present(drawable)
        committed = true
        command.commit()
    }

    private func prepareBlur(command: MTLCommandBuffer, input: MTLTexture, revision: UInt64?) throws -> MTLTexture {
        if blurPyramid?.width != input.width || blurPyramid?.height != input.height || blurPyramid?.pixelFormat != input.pixelFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: input.pixelFormat,
                width: input.width, height: input.height, mipmapped: true)
            descriptor.mipmapLevelCount = min(9, descriptor.mipmapLevelCount)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw LidFoldError.message("Blur texture allocation failed.")
            }
            var levels: [MTLTexture] = []
            for level in 0..<texture.mipmapLevelCount {
                guard let view = texture.makeTextureView(pixelFormat: texture.pixelFormat, textureType: .type2D,
                    levels: level..<(level+1), slices: 0..<1) else { throw LidFoldError.message("Blur level unavailable.") }
                levels.append(view)
            }
            blurPyramid = texture; blurLevels = levels
            blurredRevision = nil
        }
        if let revision, blurredRevision == revision, let pyramid = blurPyramid { return pyramid }
        guard let pyramid = blurPyramid, let blit = command.makeBlitCommandEncoder() else {
            throw LidFoldError.message("Blur copy encoder unavailable.")
        }
        blit.copy(from: input, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: input.width, height: input.height, depth: 1),
            to: pyramid, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        for level in 1..<blurLevels.count {
            guard let encoder = command.makeComputeCommandEncoder() else { throw LidFoldError.message("Blur encoder unavailable.") }
            encoder.setComputePipelineState(downsamplePipeline)
            encoder.setTexture(blurLevels[level-1], index: 0)
            encoder.setTexture(blurLevels[level], index: 1)
            encoder.dispatchThreads(MTLSize(width: blurLevels[level].width, height: blurLevels[level].height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }
        blurredRevision = revision
        return pyramid
    }

    func encode(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, texture: MTLTexture, uniforms: LidFoldUniforms, sourceRevision: UInt64? = nil) throws {
        let moving = uniforms.progress > 0.00001 && uniforms.progress < 1
        let needsBlur = moving && uniforms.blur > 0
        let blurred = needsBlur ? try prepareBlur(command: command, input: texture, revision:sourceRevision) : texture
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw LidFoldError.message("Render encoder unavailable.") }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(blurred, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LidFoldUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

}

private struct LidFoldGPUResources: @unchecked Sendable {
    let frame: LidFoldFrame
    let texture: CVMetalTexture
}
