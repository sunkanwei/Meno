import XCTest
import MetalKit

final class LidFoldTests: XCTestCase {
    func testSensorReportRejectsTruncatedAndWrongReports() {
        XCTAssertNil(LidFoldSensor.decodeReport([]))
        XCTAssertNil(LidFoldSensor.decodeReport([1, 90]))
        XCTAssertNil(LidFoldSensor.decodeReport([2, 90, 0]))
    }

    func testSensorReportBoundsAndLittleEndian() {
        for angle in [0, 7, 90, 140, 180] {
            XCTAssertEqual(LidFoldSensor.decodeReport([1, UInt8(angle), 0]), Double(angle))
        }
        XCTAssertNil(LidFoldSensor.decodeReport([1, 181, 0]))
        XCTAssertNil(LidFoldSensor.decodeReport([1, 0, 1]))
        XCTAssertEqual(LidFoldSensor.decodeReport([99, 1, 90, 0].dropFirst()), 90)
    }

    @MainActor
    func testRenderingPreservesOpenDesktopAndBlacksOutClosedDesktop() throws {
        let (renderer, input) = try makeRenderer()
        let open = try render(renderer, input: input, progress: 0)
        XCTAssertEqual(open, Array(repeating: [60, 120, 200, 255] as [UInt8], count: 64 * 64).flatMap { $0 })
        let closed = try render(renderer, input: input, progress: 1)
        XCTAssertEqual(closed, Array(repeating: [0, 0, 0, 255] as [UInt8], count: 64 * 64).flatMap { $0 })
    }

    @MainActor
    func testPartialFoldAndRestartRenderWithoutStaleDesktop() throws {
        let (renderer, input) = try makeRenderer()
        let folded = try render(renderer, input: input, progress: 0.5, revision: 1)
        let center = (32 * 64 + 32) * 4
        XCTAssertGreaterThan(folded[center + 2], 0)
        XCTAssertLessThan(folded[center + 2], 200)
        XCTAssertEqual(folded[center + 3], 255)
        XCTAssertLessThan(folded[2], folded[center + 2])
        renderer.clearFrame()
        let black = [UInt8](repeating: 0, count: 64 * 64 * 4)
        black.withUnsafeBytes {
            input.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: 64 * 4)
        }
        let restarted = try render(renderer, input: input, progress: 0.5, revision: 2)
        XCTAssertEqual(restarted[center + 2], 0)
        XCTAssertEqual(restarted[center + 3], 255)
    }

    @MainActor
    private func makeRenderer() throws -> (LidFoldRenderer, MTLTexture) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal is required for lid-fold acceptance")
        let renderer = try LidFoldRenderer(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: 64, height: 64, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pixels = Array(repeating: [60, 120, 200, 255] as [UInt8], count: 64 * 64).flatMap { $0 }
        pixels.withUnsafeBytes {
            input.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: 64 * 4)
        }
        return (renderer, input)
    }

    @MainActor
    private func render(_ renderer: LidFoldRenderer, input: MTLTexture, progress: Float,
                        revision: UInt64 = 0) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: 64, height: 64, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let output = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        var uniforms = LidFoldUniforms()
        uniforms.progress = progress
        uniforms.size = SIMD2(64, 64)
        try renderer.encode(command: command, pass: pass, texture: input,
                            uniforms: uniforms, sourceRevision: revision)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        pixels.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: 64 * 4,
                            from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        }
        return pixels
    }
}
