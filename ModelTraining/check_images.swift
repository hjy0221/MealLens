import Foundation
import ImageIO

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".").standardizedFileURL
let fm = FileManager.default
let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff"]
var invalid: [String] = []
if let iterator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
    for case let url as URL in iterator where extensions.contains(url.pathExtension.lowercased()) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else {
            invalid.append(url.path)
            print("invalid: \(url.path)")
            continue
        }
    }
}
print("invalid_count=\(invalid.count)")
exit(invalid.isEmpty ? 0 : 1)
