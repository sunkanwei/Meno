import Foundation

struct MouseConnectionDiagnostics {
    private var sentFrames = 0
    private var sentSamples = 0
    private var maximumBatchSize = 0
    private var maximumMailboxWait: Duration = .zero
    private var writeCount = 0
    private var totalWriteTime: Duration = .zero
    private var maximumWriteTime: Duration = .zero
    private var waitAbove8ms = 0
    private var waitAbove16ms = 0
    private var waitAbove50ms = 0
    private var writeTimeouts = 0

    mutating func recordMailboxWait(_ duration: Duration) {
        maximumMailboxWait = max(maximumMailboxWait, duration)
        if duration >= .milliseconds(8) { waitAbove8ms += 1 }
        if duration >= .milliseconds(16) { waitAbove16ms += 1 }
        if duration >= .milliseconds(50) { waitAbove50ms += 1 }
    }

    mutating func recordMouseMove(batchSize: Int) {
        sentFrames += 1
        sentSamples += batchSize
        maximumBatchSize = max(maximumBatchSize, batchSize)
    }

    mutating func recordWrite(_ duration: Duration) {
        writeCount += 1
        totalWriteTime += duration
        maximumWriteTime = max(maximumWriteTime, duration)
    }

    mutating func recordWriteTimeout() {
        writeTimeouts += 1
    }

    mutating func takeReport(mailbox: MouseMailboxDiagnostics) -> String? {
        defer { self = MouseConnectionDiagnostics() }
        guard mailbox.capturedSamples > 0 || sentFrames > 0
                || mailbox.mergedMovements > 0 || writeTimeouts > 0 else { return nil }
        let averageBatch = sentFrames == 0 ? 0
            : Double(sentSamples) / Double(sentFrames)
        let averageWrite = writeCount == 0 ? 0
            : microseconds(totalWriteTime) / Double(writeCount)
        return String(
            format: "Mouse TX interval captured=%d frames=%d avgBatch=%.2f maxBatch=%d mailbox=%d/%d merged=%d return=%d wall=%d heartbeatDedupe=%d waitMaxUs=%.0f wait8/16/50=%d/%d/%d writeAvg/MaxUs=%.0f/%.0f writeTimeout=%d",
            mailbox.capturedSamples,
            sentFrames,
            averageBatch,
            maximumBatchSize,
            mailbox.currentDepth,
            mailbox.maximumDepth,
            mailbox.mergedMovements,
            mailbox.returnCandidates,
            mailbox.blockedReturnCandidates,
            mailbox.deduplicatedHeartbeats,
            microseconds(maximumMailboxWait),
            waitAbove8ms,
            waitAbove16ms,
            waitAbove50ms,
            averageWrite,
            microseconds(maximumWriteTime),
            writeTimeouts
        )
    }

    private func microseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000_000
            + Double(components.attoseconds) / 1_000_000_000_000
    }
}
