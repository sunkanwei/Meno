import Foundation

struct MouseScreenMetrics: Equatable, Sendable {
    let width: UInt32
    let height: UInt32
}

struct MousePeer: Equatable, Sendable {
    let name: String
    let driverABI: UInt16
    let screenMetrics: MouseScreenMetrics
    let capabilities: Set<CompanionCapability>

    var driverAvailable: Bool {
        driverABI > 0
    }

    var keyboardSupported: Bool {
        capabilities.contains(.keyboardState)
    }

    var remoteShutdownSupported: Bool {
        capabilities.contains(.remoteShutdown)
    }

    var routeContractSupported: Bool {
        capabilities.contains(.mouseRouteContract)
    }

}

struct MouseMoveSample: Equatable, Sendable {
    let dx: Int16
    let dy: Int16
}

struct MouseMovePayload: Equatable, Sendable {
    let controlID: UInt64
    let samples: [MouseMoveSample]
}

struct MouseEnterV2Payload: Equatable, Sendable {
    let controlID: UInt64
    let routeID: UInt64
    let normalizedY: UInt16
    let openingLowerY: UInt16
    let openingUpperY: UInt16
    let entryEdge: HorizontalDisplaySide
}

struct MouseMovementScaler: Sendable {
    let scaleX: Double
    let scaleY: Double
    let usesPhysicalScreenSize: Bool

    private var residualX = 0.0
    private var residualY = 0.0

    init(
        scaleX: Double,
        scaleY: Double,
        usesPhysicalScreenSize: Bool = false
    ) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.usesPhysicalScreenSize = usesPhysicalScreenSize
    }

    init(
        sourceWidth: Double,
        sourceHeight: Double,
        destination: MouseScreenMetrics
    ) {
        self.init(
            scaleX: Double(destination.width) / sourceWidth,
            scaleY: Double(destination.height) / sourceHeight
        )
    }

    init(
        sourceWidth: Double,
        sourceHeight: Double,
        sourceHeightMM: Double?,
        destination: MouseScreenMetrics,
        destinationHeightMM: Double?
    ) {
        guard let sourceHeightMM,
              let destinationHeightMM,
              sourceHeightMM.isFinite,
              destinationHeightMM.isFinite,
              sourceHeightMM > 0,
              destinationHeightMM > 0,
              sourceHeight.isFinite,
              sourceHeight > 0 else {
            self.init(
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                destination: destination
            )
            return
        }
        let scale = Double(destination.height) / destinationHeightMM
            * sourceHeightMM / sourceHeight
        self.init(
            scaleX: scale,
            scaleY: scale,
            usesPhysicalScreenSize: true
        )
    }

    mutating func convert(dx: Double, dy: Double) -> (dx: Int32, dy: Int32) {
        let x = Self.convert(delta: dx, scale: scaleX, residual: residualX)
        let y = Self.convert(delta: dy, scale: scaleY, residual: residualY)
        residualX = x.residual
        residualY = y.residual
        return (x.value, y.value)
    }

    mutating func reset() {
        residualX = 0
        residualY = 0
    }

    private static func convert(
        delta: Double,
        scale: Double,
        residual: Double
    ) -> (value: Int32, residual: Double) {
        let scaled = delta * scale + residual
        let integral = scaled.rounded(.towardZero)
        if integral <= Double(Int32.min) { return (Int32.min, 0) }
        if integral >= Double(Int32.max) { return (Int32.max, 0) }
        return (Int32(integral), scaled - integral)
    }
}

enum MouseWheelInput {
    private static let continuousUnitsPerLine = 3.0

    static func normalized(
        _ delta: Double,
        isContinuous: Bool,
        directionInvertedFromDevice: Bool
    ) -> Double {
        let lines = isContinuous ? delta / continuousUnitsPerLine : delta
        return directionInvertedFromDevice ? -lines : lines
    }
}

struct MouseWheelAccumulator: Sendable {
    static let maximumBufferedLines = 10.0
    private static let thresholdTolerance = 1e-9

    private(set) var pendingLines = 0.0

    mutating func add(_ deltaLines: Double) {
        guard deltaLines.isFinite else { return }
        let total = pendingLines + deltaLines
        if total.isFinite {
            pendingLines = min(
                max(total, -Self.maximumBufferedLines),
                Self.maximumBufferedLines
            )
        } else {
            pendingLines = deltaLines.sign == .minus
                ? -Self.maximumBufferedLines
                : Self.maximumBufferedLines
        }
    }

    mutating func drain(maximumLines: Int32 = .max) -> Int32 {
        precondition(maximumLines > 0)
        let tolerance = pendingLines >= 0
            ? Self.thresholdTolerance
            : -Self.thresholdTolerance
        let adjustedLines = pendingLines + tolerance
        let availableLines = Int32(adjustedLines.rounded(.towardZero))
        let lines = min(max(availableLines, -maximumLines), maximumLines)
        pendingLines -= Double(lines)
        if abs(pendingLines) < Self.thresholdTolerance {
            pendingLines = 0
        }
        return lines
    }

    mutating func reset() {
        pendingLines = 0
    }
}

enum MousePayload {
    static func enterV2(
        controlID: UInt64,
        routeID: UInt64,
        normalizedY: UInt16,
        openingLowerY: UInt16,
        openingUpperY: UInt16,
        entryEdge: HorizontalDisplaySide
    ) -> Data {
        precondition(routeID != 0)
        precondition(openingLowerY <= openingUpperY)
        var data = header(
            controlID: controlID,
            bodyCapacity: ClipboardWire.mouseEnterV2PayloadSize - 8
        )
        data.appendBigEndian(routeID)
        data.appendBigEndian(normalizedY)
        data.appendBigEndian(openingLowerY)
        data.appendBigEndian(openingUpperY)
        data.append(entryEdge.rawValue)
        return data
    }

    static func control(controlID: UInt64) -> Data {
        header(controlID: controlID, bodyCapacity: 0)
    }

    static func button(controlID: UInt64, button: UInt8, down: Bool) -> Data {
        var data = header(controlID: controlID, bodyCapacity: 2)
        data.append(button)
        data.append(down ? 1 : 0)
        return data
    }

    static func wheel(controlID: UInt64, lines: Int32) -> Data {
        var data = header(controlID: controlID, bodyCapacity: 4)
        data.appendBigEndian(UInt32(bitPattern: lines))
        return data
    }

    static func keyboard(controlID: UInt64, report: KeyboardReport) -> Data {
        var data = header(controlID: controlID, bodyCapacity: 8)
        data.append(report.payload)
        return data
    }

    static func move(controlID: UInt64, samples: [MouseMoveSample]) -> Data {
        precondition(!samples.isEmpty && samples.count <= ClipboardWire.maximumMouseMoveBatch)
        var data = header(
            controlID: controlID,
            bodyCapacity: 1 + samples.count * 4
        )
        data.append(UInt8(samples.count))
        for sample in samples {
            data.appendBigEndian(UInt16(bitPattern: sample.dx))
            data.appendBigEndian(UInt16(bitPattern: sample.dy))
        }
        return data
    }

    static func decodeControl(_ data: Data) -> UInt64? {
        decodeHeader(data, expectedBodyCount: 0)
    }

    static func decodeLeave(_ data: Data) -> (controlID: UInt64, normalizedY: UInt16)? {
        guard let controlID = decodeHeader(data, expectedBodyCount: 2) else { return nil }
        let bytes = [UInt8](data)
        return (controlID, bytes.readUInt16(at: 8))
    }

    static func decodeEnterV2(_ data: Data) -> MouseEnterV2Payload? {
        let bytes = [UInt8](data)
        guard bytes.count == ClipboardWire.mouseEnterV2PayloadSize else { return nil }
        let controlID = bytes.readUInt64(at: 0)
        let routeID = bytes.readUInt64(at: 8)
        let normalizedY = bytes.readUInt16(at: 16)
        let openingLowerY = bytes.readUInt16(at: 18)
        let openingUpperY = bytes.readUInt16(at: 20)
        guard controlID != 0,
              routeID != 0,
              openingLowerY <= openingUpperY,
              let entryEdge = HorizontalDisplaySide(rawValue: bytes[22]) else {
            return nil
        }
        return MouseEnterV2Payload(
            controlID: controlID,
            routeID: routeID,
            normalizedY: normalizedY,
            openingLowerY: openingLowerY,
            openingUpperY: openingUpperY,
            entryEdge: entryEdge
        )
    }

    static func decodeMove(_ data: Data) -> MouseMovePayload? {
        let bytes = [UInt8](data)
        guard bytes.count >= 9 else { return nil }
        let controlID = bytes.readUInt64(at: 0)
        let sampleCount = bytes[8]
        guard controlID != 0,
              sampleCount > 0,
              sampleCount <= ClipboardWire.maximumMouseMoveBatch,
              bytes.count == 9 + Int(sampleCount) * 4 else { return nil }
        let samples = stride(from: 9, to: bytes.count, by: 4).map { offset in
            MouseMoveSample(
                dx: Int16(bitPattern: bytes.readUInt16(at: offset)),
                dy: Int16(bitPattern: bytes.readUInt16(at: offset + 2))
            )
        }
        return MouseMovePayload(controlID: controlID, samples: samples)
    }

    static func split(dx: Int32, dy: Int32) -> [MouseMoveSample] {
        guard dx != 0 || dy != 0 else { return [] }
        var x = Int64(dx)
        var y = Int64(dy)
        var samples: [MouseMoveSample] = []
        while x != 0 || y != 0 {
            let partX = x.clamped(to: -32_767...32_767)
            let partY = y.clamped(to: -32_767...32_767)
            samples.append(MouseMoveSample(dx: Int16(partX), dy: Int16(partY)))
            x -= partX
            y -= partY
        }
        return samples
    }

    static func decodeHello(_ data: Data) -> MousePeer? {
        guard let hello = CompanionHello.decode(data),
              hello.audioPort == nil,
              hello.capabilities.contains(.mouseControl),
              let driverABI = hello.driverABI,
              let width = hello.screenWidth,
              let height = hello.screenHeight,
              width > 0,
              height > 0,
              width <= UInt32(Int32.max),
              height <= UInt32(Int32.max) else { return nil }
        let capabilities = hello.capabilities.intersection([
            .mouseControl,
            .keyboardState,
            .remoteShutdown,
            .mouseRouteContract,
        ])
        return MousePeer(
            name: hello.name.isEmpty ? "Windows" : hello.name,
            driverABI: driverABI,
            screenMetrics: MouseScreenMetrics(width: width, height: height),
            capabilities: capabilities
        )
    }

    private static func header(controlID: UInt64, bodyCapacity: Int) -> Data {
        precondition(controlID != 0)
        var data = Data(capacity: 8 + bodyCapacity)
        data.appendBigEndian(controlID)
        return data
    }

    private static func decodeHeader(_ data: Data, expectedBodyCount: Int) -> UInt64? {
        let bytes = [UInt8](data)
        guard bytes.count == 8 + expectedBodyCount else { return nil }
        let controlID = bytes.readUInt64(at: 0)
        guard controlID != 0 else { return nil }
        return controlID
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

private extension Array where Element == UInt8 {
    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func readUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in self[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
