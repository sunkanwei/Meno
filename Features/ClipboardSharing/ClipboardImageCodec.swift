import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ClipboardImageBudget {
    static let maximumDimension: UInt64 = 16_384
    static let maximumPixels: UInt64 = 16_777_216
    static let maximumDecodedBytes: UInt64 = 64 * 1_024 * 1_024
    private static let estimatedBytesPerPixel: UInt64 = 4

    static func accepts(width: UInt64, height: UInt64) -> Bool {
        guard width > 0,
              height > 0,
              width <= maximumDimension,
              height <= maximumDimension else { return false }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow, pixels <= maximumPixels else { return false }
        let (decodedBytes, byteOverflow) = pixels.multipliedReportingOverflow(
            by: estimatedBytesPerPixel
        )
        return !byteOverflow && decodedBytes <= maximumDecodedBytes
    }

    static func accepts(bytesPerRow: Int, height: Int) -> Bool {
        guard bytesPerRow > 0, height > 0 else { return false }
        let (bytes, overflow) = UInt64(bytesPerRow).multipliedReportingOverflow(
            by: UInt64(height)
        )
        return !overflow && bytes <= maximumDecodedBytes
    }
}

enum ClipboardImageCodec {
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png),
           validatedCGImage(from: png, requiresPNG: true) != nil {
            return png
        }
        guard let tiff = pasteboard.data(forType: .tiff),
              let image = validatedCGImage(from: tiff, requiresPNG: false) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]),
              png.count <= ClipboardWire.maximumImageSize else { return nil }
        return png
    }

    @discardableResult
    static func write(png: Data, to pasteboard: NSPasteboard) -> Bool {
        guard let cgImage = validatedCGImage(from: png, requiresPNG: true) else {
            return false
        }
        let image = NSImage(cgImage: cgImage, size: .zero)
        guard let tiff = image.tiffRepresentation,
              tiff.count <= Int(ClipboardImageBudget.maximumDecodedBytes) else {
            return false
        }
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png),
              item.setData(tiff, forType: .tiff) else {
            return false
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func isAcceptablePNG(_ data: Data) -> Bool {
        validatedCGImage(from: data, requiresPNG: true) != nil
    }

    private static func validatedCGImage(
        from data: Data,
        requiresPNG: Bool
    ) -> CGImage? {
        guard !data.isEmpty,
              data.count <= ClipboardWire.maximumImageSize,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              CGImageSourceGetCount(source) == 1 else { return nil }
        if requiresPNG {
            guard CGImageSourceGetType(source) as String? == UTType.png.identifier else {
                return nil
            }
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any],
        let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
        let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber,
        widthNumber.int64Value > 0,
        heightNumber.int64Value > 0,
        ClipboardImageBudget.accepts(
            width: widthNumber.uint64Value,
            height: heightNumber.uint64Value
        ),
        let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary),
        ClipboardImageBudget.accepts(
            bytesPerRow: image.bytesPerRow,
            height: image.height
        ) else { return nil }
        return image
    }
}
