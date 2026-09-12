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

    func testExternalOpeningNeverStartsAnAnimation() {
        var policy = LidFoldExternalPolicy()
        policy.read(angle: 0, reference: 100, now: 0)
        policy.read(angle: 45, reference: 100, now: 1)
        policy.read(angle: 100, reference: 100, now: 2)
        XCTAssertEqual(policy.phase, .idle)
        XCTAssertEqual(policy.target(now: 2), 0)
    }

    func testExternalClosingFollowsTheLidAndRestingRestoresDesktop() {
        var policy = LidFoldExternalPolicy()
        policy.read(angle: 100, reference: 100, now: 0)
        policy.read(angle: 60, reference: 100, now: 1)
        let first = policy.target(now: 1)
        policy.read(angle: 30, reference: 100, now: 1.5)
        XCTAssertGreaterThan(policy.target(now: 1.5), first)
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(policy.target(now: 3), 0)
    }

    func testExternalBlackWaitDoesNotFadeBackToDesktopWhileClosing() {
        var policy = LidFoldExternalPolicy()
        policy.read(angle: 100, reference: 100, now: 0)
        policy.read(angle: 7, reference: 100, now: 1)
        XCTAssertEqual(policy.target(now: 1), 1)
        policy.read(angle: 0, reference: 100, now: 2)
        policy.didClose(now: 3)
        XCTAssertEqual(policy.target(now: 8.9), 1)
        XCTAssertEqual(policy.target(now: 9), 0)
        XCTAssertEqual(policy.phase, .waitingForOpening)
        policy.didClose(now: 10)
        policy.read(angle: 0, reference: 100, now: 10)
        XCTAssertEqual(policy.target(now: 10), 0)
    }

    func testClosedAngleJitterCannotRestartTheBlackWait() {
        var policy = LidFoldExternalPolicy()
        policy.read(angle: 100, reference: 100, now: 0)
        policy.read(angle: 7, reference: 100, now: 1)
        policy.read(angle: 6, reference: 100, now: 2)
        policy.read(angle: 7, reference: 100, now: 3)
        XCTAssertEqual(policy.phase, .black(until: 9))
        XCTAssertEqual(policy.target(now: 9), 0)
        policy.read(angle: 6, reference: 100, now: 10)
        policy.read(angle: 7, reference: 100, now: 11)
        policy.didClose(now: 12)
        XCTAssertEqual(policy.phase, .waitingForOpening)
    }

    func testExternalReopeningImmediatelyCancelsBlackAndAllowsNextClosure() {
        var policy = LidFoldExternalPolicy()
        policy.read(angle: 100, reference: 100, now: 0)
        policy.read(angle: 0, reference: 100, now: 1)
        policy.read(angle: 10, reference: 100, now: 2)
        XCTAssertEqual(policy.phase, .idle)
        XCTAssertEqual(policy.target(now: 2), 0)
        policy.read(angle: 90, reference: 100, now: 3)
        policy.read(angle: 45, reference: 100, now: 4)
        XCTAssertEqual(policy.phase, .closing)
        XCTAssertGreaterThan(policy.target(now: 4), 0)
    }

    func testExternalBinaryClosureCoversMissedAngleReports() {
        var policy = LidFoldExternalPolicy()
        policy.read(angle: 100, reference: 100, now: 0)
        policy.didClose(now: 1)
        XCTAssertEqual(policy.target(now: 1), 1)
        policy.cancel()
        XCTAssertEqual(policy.target(now: 2), 0)
        policy.read(angle: 50, reference: 100, now: 3)
        XCTAssertEqual(policy.phase, .idle)
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
        // Clearing releases cached desktop data, even if the next capture
        // starts numbering its source frames from the same revision.
        let restarted = try render(renderer, input: input, progress: 0.5, revision: 1)
        XCTAssertEqual(restarted[center + 2], 0)
        XCTAssertEqual(restarted[center + 3], 255)
    }

    @MainActor
    func testBlurPreservesLightEnergyAcrossBlackAndWhiteDetails() throws {
        let (renderer, input) = try makeRenderer()
        var pixels = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 where (x + y).isMultiple(of: 2) {
                let index = (y * 64 + x) * 4
                pixels[index] = 0; pixels[index + 1] = 0; pixels[index + 2] = 0
            }
        }
        pixels.withUnsafeBytes {
            input.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: 64 * 4)
        }
        let result = try render(renderer, input: input, progress: 0.8, revision: 1)
        // Equal black/white light averages to approximately 188 in sRGB, not
        // the muddy 128 produced by averaging encoded display values.
        let center = (32 * 64 + 32) * 4
        XCTAssertGreaterThan(result[center], 170)
        XCTAssertLessThan(result[center], 200)
        XCTAssertEqual(result[center], result[center + 1])
        XCTAssertEqual(result[center], result[center + 2])
        XCTAssertEqual(result[center + 3], 255)
        // A blurred checkerboard must also stay uniform between texel centers.
        // Incorrect mip sampling can pass a single point yet leave repeated bands.
        let row = (20..<44).map { result[(8 * 64 + $0) * 4] }
        XCTAssertGreaterThan(try XCTUnwrap(row.min()), 175)
        XCTAssertLessThan(try XCTUnwrap(row.max()), 195)
        XCTAssertLessThan(Int(try XCTUnwrap(row.max())) - Int(try XCTUnwrap(row.min())), 3)
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
