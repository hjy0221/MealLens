import Foundation
import Vision

@main enum InspectVisionPhotos {
    static func main() throws {
        for url in try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: CommandLine.arguments[1]), includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            try autoreleasepool {
                let request = VNClassifyImageRequest()
                try VNImageRequestHandler(data: Data(contentsOf: url)).perform([request])
                print(url.lastPathComponent, (request.results ?? []).prefix(8).map { "\($0.identifier)=\($0.confidence)" }.joined(separator: ", "))
            }
        }
    }
}
