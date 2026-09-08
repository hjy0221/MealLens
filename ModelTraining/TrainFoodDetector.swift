import Foundation
import CreateML

setbuf(stdout, nil)

let args = CommandLine.arguments
guard (args.count == 4 || (args.count == 5 && args[4] == "--export-only")), let iterations = Int(args[3]), iterations > 0 else {
    fatalError("Usage: TrainFoodDetector dataset output iterations [--export-only]")
}
let root = URL(fileURLWithPath: args[1], isDirectory: true)
let output = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
let provenance: [String: Any] = ["dataset": root.path, "iterations": iterations,
    "algorithm": "Create ML ObjectPrint revision 1", "batch_size": 8,
    "scope": "Local noncommercial research; no portion-weight labels"]
try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("run.json"))
func source(_ split: String) -> MLObjectDetector.DataSource {
    .directoryWithImagesAndJsonAnnotation(at: root.appendingPathComponent(split))
}
let parameters = MLObjectDetector.ModelParameters(validation: .dataSource(source("validation")),
    batchSize: 8, maxIterations: iterations, gridSize: CGSize(width: 13, height: 13),
    algorithm: .transferLearning(.objectPrint(revision: 1)))
let detector = try MLObjectDetector(trainingData: source("train"), parameters: parameters, annotationType: .boundingBox(units: .pixel, origin: .topLeft, anchor: .center))
try detector.write(to: output.appendingPathComponent("FoodDetector.mlmodel"), metadata: MLModelMetadata(
    author: "MealLens local research", shortDescription: "UEC FOOD-256 class-agnostic food detector. Noncommercial research only.", version: "1"))
print("Exported FoodDetector.mlmodel")
// The separate evaluator measures the exact Vision/NMS path used by the app.
if args.count == 5 { exit(0) }
let metrics = detector.evaluation(on: source("test"))
guard metrics.isValid else { throw metrics.error ?? CocoaError(.coderInvalidValue) }
let numeric: [String: Any] = ["iterations": iterations, "test_mAP50": metrics.meanAveragePrecision.IoU50,
    "test_mAP": metrics.meanAveragePrecision.variedIoU,
    "validation_mAP50": detector.validationMetrics.meanAveragePrecision.IoU50]
try JSONSerialization.data(withJSONObject: numeric, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("metrics.json"))
let report = "Training\n\(detector.trainingMetrics)\nValidation\n\(detector.validationMetrics)\nHeld-out test\n\(metrics)\n"
try report.write(to: output.appendingPathComponent("evaluation.txt"), atomically: true, encoding: .utf8)
print(report)
