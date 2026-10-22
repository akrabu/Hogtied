import AppKit
import Foundation

@main
struct IconGenerator {
    @MainActor
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        guard CommandLine.arguments.count > 2,
              let source = NSImage(contentsOfFile: CommandLine.arguments[2]) else {
            throw NSError(domain: "HogtiedIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass the approved artwork PNG."])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let image = source
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let suffix = scale == 2 ? "@2x" : ""
                try rep.representation(using: .png, properties: [:])!
                    .write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
        // Modern ICNS entries contain PNG data. Write the container directly
        // so packaging also works where iconutil's image services are unavailable.
        let entries = [
            ("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
            ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
            ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
            ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
            ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")
        ]
        func encodedLength(_ length: Int) -> Data {
            var bigEndian = UInt32(length).bigEndian
            return withUnsafeBytes(of: &bigEndian) { Data($0) }
        }
        var payload = Data()
        for (type, filename) in entries {
            let png = try Data(contentsOf: directory.appendingPathComponent(filename))
            payload.append(Data(type.utf8))
            payload.append(encodedLength(png.count + 8))
            payload.append(png)
        }
        var container = Data("icns".utf8)
        container.append(encodedLength(payload.count + 8))
        container.append(payload)
        try container.write(to: directory.deletingPathExtension().appendingPathExtension("icns"))
    }
}
