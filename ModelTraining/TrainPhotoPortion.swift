import Foundation
import Vision
import CoreML
import CreateML
import CryptoKit

// Research experiment: overhead RGB -> Vision features -> measured plate totals.
// Uses the official depth split, with validation grouped by capture day.
struct PortionSample: Codable {
    let id: String
    let split: String
    let sha256: String
    let grams: Double
    let calories: Double
    let features: [Float]
}

enum PortionFailure: Error { case invalid(String) }

func extract(root: URL, cache: URL) throws -> [PortionSample] {
    if FileManager.default.fileExists(atPath: cache.path) {
        return try JSONDecoder().decode([PortionSample].self, from: Data(contentsOf: cache))
    }
    func ids(_ split: String) throws -> Set<String> {
        Set(try String(contentsOf: root.appendingPathComponent("dish_ids/splits/depth_\(split)_ids.txt"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).map(String.init))
    }
    let training = try ids("train"), testing = try ids("test")
    guard training.isDisjoint(with: testing) else { throw PortionFailure.invalid("Overlapping official splits") }
    var labels: [String: (Double, Double)] = [:]
    for cafe in [1, 2] {
        let csv = try String(contentsOf: root.appendingPathComponent("metadata/dish_metadata_cafe\(cafe).csv"), encoding: .utf8)
        for line in csv.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 6, let calories = Double(fields[1]), let grams = Double(fields[2]),
                  grams > 0, calories > 0, grams.isFinite, calories.isFinite else { continue }
            labels[String(fields[0])] = (grams, calories)
        }
    }
    var samples: [PortionSample] = []
    var excluded: [[String: String]] = []
    for id in training.union(testing).sorted() {
        try autoreleasepool {
            guard let (grams, calories) = labels[id] else {
                excluded.append(["id": id, "reason": "Missing or non-positive nutrition target"])
                return
            }
            let url = root.appendingPathComponent("imagery/realsense_overhead/\(id)/rgb.png")
            guard FileManager.default.fileExists(atPath: url.path) else {
                excluded.append(["id": id, "reason": "No overhead RGB file"])
                return
            }
            let data = try Data(contentsOf: url)
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = VNGenerateImageFeaturePrintRequestRevision2
            request.imageCropAndScaleOption = .centerCrop
            try VNImageRequestHandler(data: data).perform([request])
            guard let result = request.results?.first, result.elementType == .float else {
                throw PortionFailure.invalid("Invalid feature print: \(id)")
            }
            let features = result.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard features.count == result.elementCount, features.allSatisfy(\.isFinite) else {
                throw PortionFailure.invalid("Invalid feature values")
            }
            let timestamp = Int(id.split(separator: "_")[1])!
            let split = testing.contains(id) ? "test" : (timestamp / 86400 % 5 == 0 ? "validation" : "train")
            samples.append(.init(id: id, split: split,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                grams: grams, calories: calories, features: features))
        }
        if samples.count % 250 == 0 { print("Extracted \(samples.count) RGB feature vectors") }
    }
    // Fail on duplicate photos rather than silently leaking them into evaluation.
    guard Set(samples.map(\.sha256)).count == samples.count else { throw PortionFailure.invalid("Duplicate RGB photos; audit split before training") }
    try JSONEncoder().encode(samples).write(to: cache, options: .atomic)
    try JSONSerialization.data(withJSONObject: excluded, options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent("feature-exclusions.json"))
    print("Excluded \(excluded.count) samples with missing images or invalid labels; see feature-exclusions.json")
    return samples
}

func runPortion() throws {
    guard CommandLine.arguments.count == 3 else { throw PortionFailure.invalid("Usage: TrainPhotoPortion <nutrition5k-root> <new-run-directory>") }
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: output.appendingPathComponent("evaluation.json").path) else {
        throw PortionFailure.invalid("Completed run already exists")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let samples = try extract(root: root, cache: root.appendingPathComponent("vision-r2-features.json"))
    let groups = Dictionary(grouping: samples, by: \.split)
    let train = groups["train"]!, validation = groups["validation"]!, test = groups["test"]!
    let dimensions = samples[0].features.count
    print("Portion experiment: \(train.count) train / \(validation.count) validation / \(test.count) test; \(dimensions) features")
    let columns = (0..<dimensions).map { "f\($0)" }
    func target(_ row: PortionSample, _ name: String) -> Double { name == "grams" ? row.grams : row.calories }
    func table(_ rows: [PortionSample], _ name: String) -> MLDataTable {
        var table = MLDataTable()
        for i in 0..<dimensions {
            table.addColumn(MLDataColumn(rows.map { Double($0.features[i]) }), named: columns[i])
        }
        table.addColumn(MLDataColumn(rows.map { log(target($0, name)) }), named: "log_\(name)")
        return table
    }
    var reports: [String: Any] = [:]
    for name in ["grams", "calories"] {
        let parameters = MLBoostedTreeRegressor.ModelParameters(validation: .table(table(validation, name)),
            maxDepth: 4, maxIterations: 120, randomSeed: 42, stepSize: 0.08, earlyStoppingRounds: 15,
            rowSubsample: 0.8, columnSubsample: 0.8)
        let regressor = try MLBoostedTreeRegressor(trainingData: table(train, name), targetColumn: "log_\(name)",
            featureColumns: columns, parameters: parameters)
        let modelURL = output.appendingPathComponent("Photo\(name.capitalized).mlmodel")
        try regressor.write(to: modelURL, metadata: MLModelMetadata(author: "MealLens; Nutrition5k data by Google Research",
            shortDescription: "Experimental log \(name) from Vision feature print revision 2; overhead plates only.", version: "0.1",
            additional: ["data_source": "https://github.com/google-research-datasets/Nutrition5k", "data_license": "CC BY 4.0", "vision_revision": "2", "crop": "centerCrop"]))
        let model = try MLModel(contentsOf: MLModel.compileModel(at: modelURL))
        let sorted = train.map { target($0, name) }.sorted()
        let median = sorted[sorted.count / 2]
        var predictions: [[String: Any]] = []
        var absolute = 0.0, squared = 0.0, baseline = 0.0, percent = 0.0
        for row in test {
            let inputs = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($0.element, Double(row.features[$0.offset])) })
            let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
            guard let value = result.featureValue(for: "log_\(name)")?.doubleValue else { throw PortionFailure.invalid("Missing prediction") }
            let prediction = exp(value), truth = target(row, name)
            guard prediction.isFinite, prediction > 0 else { throw PortionFailure.invalid("Invalid prediction") }
            let error = abs(prediction - truth)
            absolute += error; squared += error * error; baseline += abs(median - truth); percent += error / truth
            predictions.append(["id": row.id, "actual": truth, "predicted": prediction])
        }
        let count = Double(test.count)
        reports[name] = ["mae": absolute / count, "rmse": sqrt(squared / count), "mape": percent / count,
            "train_median_baseline": median, "baseline_mae": baseline / count,
            "mae_improvement": 1 - absolute / baseline, "predictions": predictions]
        print("\(name): test MAE \(absolute/count), constant baseline \(baseline/count), improvement \(1-absolute/baseline)")
    }
    let report: [String: Any] = ["status": "research_not_deployed", "dataset": "Nutrition5k overhead RGB",
        "source": "https://github.com/google-research-datasets/Nutrition5k", "license": "CC BY 4.0",
        "feature_extractor": "VNGenerateImageFeaturePrintRequest revision 2, centerCrop", "feature_count": dimensions,
        "train_count": train.count, "validation_count": validation.count, "test_count": test.count,
        "split": "Official depth train/test. Validation: training capture day (timestamp / 86400) modulo 5 == 0.",
        "hyperparameters": "Boosted trees, log target, depth 4, max 120 iterations, step 0.08; early stop on validation only",
        "metrics": reports, "limitations": ["US cafeteria overhead plates; no Korean soup or smartphone validation", "No depth or reference scale", "Image estimates are not measured nutrition"]]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("evaluation.json"))
    print("Portion experiment completed; models remain outside the app pending validation")
}

do { try runPortion() } catch { fputs("Portion training stopped: \(error)\n", stderr); exit(1) }
