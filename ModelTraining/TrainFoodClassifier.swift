import Foundation
import CreateML
import CoreML
import Vision
import ImageIO
import CryptoKit

struct TrainingFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func fail(_ text: String) throws -> Never { throw TrainingFailure(message: text) }
let fm = FileManager.default
let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff"]

func images(in root: URL) throws -> [URL] {
    guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { try fail("Missing dataset directory: \(root.path)") }
    return iterator.compactMap { $0 as? URL }.filter { imageExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
}
func validate(_ dataset: URL) throws -> [String: [URL]] {
    var hashes = Set<String>()
    var bySplit: [String: [URL]] = [:]
    var expectedLabels: Set<String>?
    for split in ["train", "validation", "test"] {
        let root = dataset.appendingPathComponent(split)
        let photos = try images(in: root)
        let labels = Set(photos.map { $0.deletingLastPathComponent().lastPathComponent })
        guard labels.count >= 2 else { try fail("Each split needs at least two classes: \(split)") }
        if let expectedLabels, expectedLabels != labels { try fail("Class labels differ between dataset splits.") }
        expectedLabels = labels
        for photo in photos {
            guard photo.deletingLastPathComponent().deletingLastPathComponent() == root else {
                try fail("Expected split/class/image, got \(photo.path)")
            }
            let data = try Data(contentsOf: photo)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hashes.insert(digest).inserted else { try fail("Duplicate image across prepared dataset: \(photo.lastPathComponent)") }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary) != nil else {
                try fail("Unreadable image: \(photo.path)")
            }
        }
        bySplit[split] = photos
        print("Validated \(split): \(photos.count) images, \(labels.count) classes")
    }
    return bySplit
}

func run() throws {
    let args = CommandLine.arguments
    guard args.count == 3 else { try fail("Usage: TrainFoodClassifier <prepared-dataset> <new-run-output-directory>") }
    let dataset = URL(fileURLWithPath: args[1]).standardizedFileURL
    let output = URL(fileURLWithPath: args[2]).standardizedFileURL
    guard !fm.fileExists(atPath: output.path) else { try fail("Choose a new run directory; previous runs are preserved.") }
    let photos = try validate(dataset)
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    let parameters = MLImageClassifier.ModelParameters(
        validation: .dataSource(.labeledDirectories(at: dataset.appendingPathComponent("validation"))),
        // Keep the first local run memory-stable on large multi-cuisine sets.
        // Augmentation can be enabled for a later run after the baseline is
        // evaluated; Create ML's pixel-buffer pool is sensitive to mixed
        // source dimensions during augmented training.
        maxIterations: 35,
        augmentation: [.flip],
        algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 2), classifier: .logisticRegressor)
    )
    print("Training Create ML image classifier locally…")
    let started = Date()
    let classifier = try MLImageClassifier(trainingData: .labeledDirectories(at: dataset.appendingPathComponent("train")), parameters: parameters)
    let testMetrics = classifier.evaluation(on: .labeledDirectories(at: dataset.appendingPathComponent("test")))
    guard testMetrics.isValid, classifier.validationMetrics.isValid else { try fail("Evaluation failed. No model exported.") }
    let metadata = MLModelMetadata(author: "MealLens", shortDescription: "Experimental food identity classifier. Does not estimate portion weight or nutrients.",
                                   version: "0.1", additional: ["training_framework": "Create ML", "preprocessing": "Vision centerCrop", "dataset_manifest": "manifest.json"])
    let modelURL = output.appendingPathComponent("FoodClassifier.mlmodel")
    try classifier.write(to: modelURL, metadata: metadata)
    // Evaluate the exported model through the SAME Vision request used in the iOS app.
    let compiled = try MLModel.compileModel(at: modelURL)
    let visionModel = try VNCoreMLModel(for: MLModel(contentsOf: compiled))
    var correct = 0
    var top3 = 0
    var confusion: [String: [String: Int]] = [:]
    var predictions: [[String: Any]] = []
    for photo in photos["test"]! {
        let expected = photo.deletingLastPathComponent().lastPathComponent
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .centerCrop
        try VNImageRequestHandler(url: photo).perform([request])
        guard let observations = request.results as? [VNClassificationObservation], let first = observations.first else { try fail("Exported model has incompatible outputs.") }
        if first.identifier == expected { correct += 1 }
        if observations.prefix(3).contains(where: { $0.identifier == expected }) { top3 += 1 }
        confusion[expected, default: [:]][first.identifier, default: 0] += 1
        predictions.append(["image": photo.lastPathComponent, "expected": expected,
                            "top3": observations.prefix(3).map { ["label": $0.identifier, "score": $0.confidence] as [String: Any] }])
    }
    let count = photos["test"]!.count
    let report: [String: Any] = ["status": "experimental_evaluated_not_deployed", "training_seconds": Date().timeIntervalSince(started),
        "train_accuracy": 1 - classifier.trainingMetrics.classificationError,
        "validation_accuracy": 1 - classifier.validationMetrics.classificationError,
        "createml_test_accuracy": 1 - testMetrics.classificationError,
        "vision_test_top1": Double(correct) / Double(count), "vision_test_top3": Double(top3) / Double(count),
        "test_count": count, "confusion": confusion, "predictions": predictions,
        "limitations": ["No portion or calorie inference", "No calibrated rejection threshold", "Held-out accuracy is not a real-world guarantee"]]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("evaluation.json"))
    try testMetrics.confusionDataFrame.writeCSV(to: output.appendingPathComponent("confusion.csv"))
    try testMetrics.precisionRecallDataFrame.writeCSV(to: output.appendingPathComponent("precision-recall.csv"))
    try fm.copyItem(at: dataset.appendingPathComponent("manifest.json"), to: output.appendingPathComponent("manifest.json"))
    print("Exported \(modelURL.path). Vision top-1: \(correct)/\(count), top-3: \(top3)/\(count). Review evaluation before adding to app.")
}
do { try run() } catch { fputs("Training stopped: \(error.localizedDescription)\n", stderr); exit(1) }
