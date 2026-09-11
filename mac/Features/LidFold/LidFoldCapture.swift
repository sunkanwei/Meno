import AppKit
@preconcurrency import ScreenCaptureKit
import CoreMedia

struct LidFoldFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let revision: UInt64
}

@MainActor
final class LidFoldCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var generation = 0
    private var revision: UInt64 = 0
    private var starting = false
    var onFrame: ((LidFoldFrame) -> Void)?
    var onUnavailable: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var isRunning: Bool { stream != nil || starting }

    func start(displayID: CGDirectDisplayID) async throws {
        guard !isRunning else { return }
        generation += 1
        let token = generation
        starting = true
        defer { if token == generation { starting = false } }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard token == generation, !Task.isCancelled else { return }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw LidFoldError.displayUnavailable
        }
        guard let own = content.applications.first(where: { $0.processID == getpid() }) else {
            throw LidFoldError.message("无法排除动效自身，已停止捕获。")
        }
        // Exclude our process even before its overlay becomes visible to prevent recursion.
        let filter = SCContentFilter(display: display, excludingApplications: [own], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let pixelWidth = CGDisplayPixelsWide(displayID)
        let pixelHeight = CGDisplayPixelsHigh(displayID)
        guard pixelWidth > 0, pixelHeight > 0 else { throw LidFoldError.displayUnavailable }
        let width = min(2560, pixelWidth)
        configuration.width = width
        configuration.height = max(1, Int(Double(width) * Double(pixelHeight) / Double(pixelWidth)))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        stream = newStream
        do {
            try await newStream.startCapture()
            if token != generation { try? await newStream.stopCapture() }
        } catch {
            if token == generation { stream = nil }
            throw error
        }
    }

    func stop() {
        generation += 1
        starting = false
        let previous = stream
        stream = nil
        if let previous { Task { try? await previous.stopCapture() } }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        guard let raw = attachments?.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        // Retain the immutable image, not the non-Sendable sample, across isolation.
        let image = sampleBuffer.imageBuffer.map { LidFoldFrame(buffer: $0, revision: 0) }
        MainActor.assumeIsolated {
            guard self.stream === stream else { return }
            if (status == .complete || status == .started), let image {
                revision &+= 1
                onFrame?(LidFoldFrame(buffer: image.buffer, revision: revision))
            } else if status == .blank || status == .suspended || status == .stopped {
                onUnavailable?()
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.onFailure?(error)
        }
    }
}
