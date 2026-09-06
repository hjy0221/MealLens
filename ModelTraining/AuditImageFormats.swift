import Foundation
import ImageIO
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
var counts: [String: Int] = [:]
var examples: [String: String] = [:]
for case let url as URL in files where url.pathExtension == "jpg" {
    autoreleasepool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { fatalError(url.path) }
        let color = "\(properties[kCGImagePropertyColorModel] ?? "unknown") depth=\(properties[kCGImagePropertyDepth] ?? "unknown")"
        counts[color, default: 0] += 1
        examples[color] = url.path
    }
}
print(counts)
print(examples)
