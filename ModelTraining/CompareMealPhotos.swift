import Foundation
import CoreML
import Vision

// Local reproduction check. Photos and output stay in ignored work folders.
@main enum CompareMealPhotos {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { fatalError("CompareMealPhotos <old.mlmodel> <new.mlmodel> <photos-directory> <report.json>") }
        let old = try VNCoreMLModel(for: MLModel(contentsOf: MLModel.compileModel(at: URL(fileURLWithPath: args[1]))))
        let new = try MLModel(contentsOf: MLModel.compileModel(at: URL(fileURLWithPath: args[2])))
        let metadata = new.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        let mapping = try JSONDecoder().decode([String: String].self, from: Data(metadata!["food_label_map"]!.utf8))
        let probability = new.modelDescription.predictedProbabilitiesName!
        var report: [[String: Any]] = []
        for url in try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: args[3]), includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            try autoreleasepool {
                let photo = try PhotoPreparation.prepare(Data(contentsOf: url))
                let request = VNCoreMLRequest(model: old)
                request.imageCropAndScaleOption = .centerCrop
                try VNImageRequestHandler(data: photo).perform([request])
                let oldScores = (request.results as! [VNClassificationObservation]).prefix(5).map { ["label": $0.identifier, "score": $0.confidence] as [String: Any] }
                let features = try PhotoFeatures.extract(photo)
                let result = try new.prediction(from: PhotoFeatures.provider(features))
                let scores = result.featureValue(for: probability)!.dictionaryValue.map { ($0.key as! String, $0.value.doubleValue) }.sorted { $0.1 > $1.1 }
                let newScores = scores.prefix(5).map { ["label": mapping[$0.0] ?? $0.0, "score": $0.1] as [String: Any] }
                report.append(["photo": url.lastPathComponent, "old": oldScores, "new": newScores])
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[4]))
        print("Compared \(report.count) photos")
    }
}
