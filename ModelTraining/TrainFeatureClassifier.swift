import Foundation
import CreateML
import CoreML
import CryptoKit

// Bypass MLImageClassifier's failing bulk image loader. Extract Vision
// features one image at a time and train the classifier on numeric columns.
@main enum TrainFeatureClassifier {
    struct Record: Decodable { let prepared: String; let label: String; let split: String; let sha256: String }
    struct Manifest: Decodable { let records: [Record] }
    struct Sample { let record: Record; let features: [Float] }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { fatalError("TrainFeatureClassifier <prepared-dataset> <new-output>") }
        let root = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
        guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Output already exists") }
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let records = try JSONDecoder().decode(Manifest.self, from: manifestData).records
        guard Set(records.map(\.sha256)).count == records.count else { fatalError("Duplicate source photos") }
        let mappingData = try Data(contentsOf: root.appendingPathComponent("class-labels.json"))
        let mapping = try JSONDecoder().decode([String: String].self, from: mappingData)
        let cache = root.appendingPathComponent("fp2-centerCrop-photoPreparation-v1")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var samples: [Sample] = []
        let started = Date()
        for record in records {
            try autoreleasepool {
                let path = cache.appendingPathComponent(record.sha256 + ".f32")
                let values: [Float]
                if FileManager.default.fileExists(atPath: path.path) {
                    let data = try Data(contentsOf: path)
                    guard data.count == 768 * 4 else { fatalError("Invalid cached features") }
                    values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                } else {
                    let data = try Data(contentsOf: root.appendingPathComponent(record.prepared))
                    values = try PhotoFeatures.extract(PhotoPreparation.prepare(data))
                    try values.withUnsafeBytes { try Data($0).write(to: path, options: .atomic) }
                }
                guard values.count == 768, values.allSatisfy(\.isFinite) else { fatalError("Invalid features") }
                samples.append(Sample(record: record, features: values))
            }
            if samples.count % 1000 == 0 { print("Features \(samples.count)/\(records.count), elapsed \(Int(Date().timeIntervalSince(started)))s"); fflush(stdout) }
        }
        let groups = Dictionary(grouping: samples, by: { $0.record.split })
        let train = groups["train"]!, validation = groups["validation"]!, test = groups["test"]!
        let columns = (0..<768).map { "f\($0)" }
        func table(_ rows: [Sample]) -> MLDataTable {
            var table = MLDataTable()
            for i in 0..<768 { table.addColumn(MLDataColumn(rows.map { Double($0.features[i]) }), named: columns[i]) }
            table.addColumn(MLDataColumn(rows.map { $0.record.label }), named: "food")
            return table
        }
        print("Training \(Set(records.map(\.label)).count) classes: \(train.count) train / \(validation.count) validation / \(test.count) test"); fflush(stdout)
        let parameters = MLLogisticRegressionClassifier.ModelParameters(validation: .table(table(validation)),
            maxIterations: 50, l2Penalty: 0.01, convergenceThreshold: 0.001, featureRescaling: true)
        let classifier = try MLLogisticRegressionClassifier(trainingData: table(train), targetColumn: "food", featureColumns: columns, parameters: parameters)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = output.appendingPathComponent("FoodIdentity.mlmodel")
        try classifier.write(to: url, metadata: MLModelMetadata(author: "MealLens; AI Hub Korean Food and Food-101",
            shortDescription: "251-class experimental food classifier from Vision revision 2 features, including tteokbokki.", version: "0.3",
            additional: ["food_label_map": String(data: mappingData, encoding: .utf8)!, "feature_count": "768", "vision_revision": "2", "crop": "centerCrop", "preprocessing": "PhotoPreparation.prepare", "training_dataset": "AI Hub Korean Food 150 + Food-101 101"]))
        let model = try MLModel(contentsOf: MLModel.compileModel(at: url))
        let probabilityName = model.modelDescription.predictedProbabilitiesName!
        var predictions: [[String: Any]] = []
        var counts: [String: [Int]] = [:]
        var confusion: [String: [String: Int]] = [:]
        for sample in test {
            let prediction = try model.prediction(from: PhotoFeatures.provider(sample.features))
            let scores = prediction.featureValue(for: probabilityName)!.dictionaryValue
                .map { ($0.key as! String, $0.value.doubleValue) }.sorted { $0.1 > $1.1 }
            let expected = mapping[sample.record.label] ?? sample.record.label
            let first = mapping[scores[0].0] ?? scores[0].0
            let source = expected.components(separatedBy: "__")[0]
            for group in [source, "all"] {
                var value = counts[group, default: [0,0,0]]
                value[0] += 1; value[1] += first == expected ? 1 : 0
                value[2] += scores.prefix(3).contains(where: { $0.0 == sample.record.label }) ? 1 : 0
                counts[group] = value
            }
            confusion[expected, default: [:]][first, default: 0] += 1
            predictions.append(["image": sample.record.sha256 + ".jpg", "expected": expected,
                "top3": scores.prefix(3).map { ["label": mapping[$0.0] ?? $0.0, "score": $0.1] as [String: Any] }])
        }
        let metrics = counts.mapValues { ["count": Double($0[0]), "top1": Double($0[1])/Double($0[0]), "top3": Double($0[2])/Double($0[0])] }
        let report: [String: Any] = ["status": "trained_evaluated_review_before_deployment", "sources": metrics,
            "training_accuracy": 1-classifier.trainingMetrics.classificationError,
            "validation_accuracy": 1-classifier.validationMetrics.classificationError,
            "seconds": Date().timeIntervalSince(started), "predictions": predictions, "confusion": confusion,
            "limitations": ["Class coverage is not guaranteed real-world recognition", "Korean capture groups unknown; near-duplicate leakage possible", "Not a portion or nutrition model", "No calibrated non-food rejection"]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("evaluation.json"))
        try manifestData.write(to: output.appendingPathComponent("manifest.json"))
        print("Feature classifier completed: \(metrics)"); fflush(stdout)
    }
}
