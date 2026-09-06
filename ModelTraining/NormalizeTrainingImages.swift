import Foundation
import ImageIO
import UniformTypeIdentifiers

// Input records retain original SHA-256, source, class and split. Orientation
// is applied before downsampling. This bounds image decoding at training time.
struct PhotoRecord: Decodable { let source: String; let prepared: String }
let args = CommandLine.arguments
guard args.count == 3 else { fatalError("NormalizeTrainingImages <manifest.json> <output-directory>") }
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
struct Manifest: Decodable { let records: [PhotoRecord] }
let manifest = try JSONDecoder().decode(Manifest.self, from: data)
let root = URL(fileURLWithPath: args[2])
for (index, record) in manifest.records.enumerated() {
    try autoreleasepool {
        let target = root.appendingPathComponent(record.prepared)
        if FileManager.default.fileExists(atPath: target.path) { return }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: record.source) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 384,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let output = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    }
    if index % 2000 == 0 { print("Normalized \(index)/\(manifest.records.count)"); fflush(stdout) }
}
try data.write(to: root.appendingPathComponent("manifest.json"))
print("Normalized \(manifest.records.count) images")
