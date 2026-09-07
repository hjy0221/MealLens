import Foundation
import CoreML
import Vision

@main enum EvaluateIdentityModels {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { fatalError("EvaluateIdentityModels <old-model> <new-model> <test-root> <report>") }
        let old = try VNCoreMLModel(for: MLModel(contentsOf: MLModel.compileModel(at: URL(fileURLWithPath: args[1]))))
        let new = try FoodIdentityInference(modelURL: MLModel.compileModel(at: URL(fileURLWithPath: args[2])))
        let iterator = FileManager.default.enumerator(at: URL(fileURLWithPath: args[3]), includingPropertiesForKeys: nil)!
        let photos = iterator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jpg" && $0.deletingLastPathComponent().lastPathComponent.hasPrefix("food101__") }
        var oldCorrect = 0, newCorrect = 0, oldTop3 = 0, newTop3 = 0
        var rows: [[String: Any]] = []
        for photo in photos {
            try autoreleasepool {
                let data = try PhotoPreparation.prepare(Data(contentsOf: photo))
                let expected = photo.deletingLastPathComponent().lastPathComponent
                let request = VNCoreMLRequest(model: old); request.imageCropAndScaleOption = .centerCrop
                try VNImageRequestHandler(data: data).perform([request])
                let a = (request.results as! [VNClassificationObservation]).prefix(3).map(\.identifier)
                let b = try new.classify(features: PhotoFeatures.extract(data)).prefix(3).map(\.identifier)
                oldCorrect += a.first == expected ? 1 : 0; newCorrect += b.first == expected ? 1 : 0
                oldTop3 += a.contains(expected) ? 1 : 0; newTop3 += b.contains(expected) ? 1 : 0
                rows.append(["image": photo.lastPathComponent, "expected": expected, "old": a, "new": Array(b)])
            }
        }
        let count = Double(photos.count)
        let result: [String: Any] = ["test_count": photos.count,
            "old_top1": Double(oldCorrect)/count, "old_top3": Double(oldTop3)/count,
            "new_top1": Double(newCorrect)/count, "new_top3": Double(newTop3)/count,
            "preprocessing": "Same fixed Food-101 holdout, 384px normalized JPEG then app PhotoPreparation; centerCrop in both paths",
            "classification": "Raw exact labels; broad display names excluded from accuracy", "predictions": rows]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[4]))
        print("Compared \(photos.count) images: old \(oldCorrect), new \(newCorrect) correct")
    }
}
