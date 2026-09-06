import Foundation
import CoreML
import Vision
import CryptoKit

// Evaluate a model on the exact prepared test inputs, grouped by source.
let args = CommandLine.arguments
guard args.count == 4 else { fatalError("EvaluateClassifier <model.mlmodel> <test-directory> <report.json>") }
let modelURL = URL(fileURLWithPath: args[1])
let root = URL(fileURLWithPath: args[2])
let compiled = try MLModel.compileModel(at: modelURL)
let model = try VNCoreMLModel(for: MLModel(contentsOf: compiled))
let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
let photos = iterator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }
var predictions: [[String: Any]] = []
var groups: [String: [Int]] = [:]
for (index, photo) in photos.enumerated() {
    try autoreleasepool {
        let label = photo.deletingLastPathComponent().lastPathComponent.precomposedStringWithCanonicalMapping
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        try VNImageRequestHandler(url: photo).perform([request])
        guard let results = request.results as? [VNClassificationObservation], !results.isEmpty else { fatalError("No predictions") }
        let labels = results.prefix(3).map { $0.identifier.precomposedStringWithCanonicalMapping }
        let source = label.components(separatedBy: "__")[0]
        var values = groups[source, default: [0,0,0]]
        values[0] += 1; values[1] += labels[0] == label ? 1 : 0; values[2] += labels.contains(label) ? 1 : 0
        groups[source] = values
        predictions.append(["image": photo.lastPathComponent, "expected": label,
            "top3": results.prefix(3).map { ["label": $0.identifier.precomposedStringWithCanonicalMapping, "score": $0.confidence] as [String: Any] }])
    }
    if index % 500 == 0 { print("Evaluated \(index)/\(photos.count)"); fflush(stdout) }
}
let metrics = groups.mapValues { ["count": Double($0[0]), "top1": Double($0[1])/Double($0[0]), "top3": Double($0[2])/Double($0[0])] }
let report: [String: Any] = ["model_sha256": SHA256.hash(data: try Data(contentsOf: modelURL)).map { String(format: "%02x", $0) }.joined(),
    "preprocessing": "384px normalized JPEG, Vision centerCrop", "sources": metrics, "predictions": predictions]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[3]))
print(metrics)
