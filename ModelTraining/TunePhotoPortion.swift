import Foundation
import CoreML
import CreateML

struct CachedPortionSample: Decodable {
    let id: String, split: String
    let grams, calories: Double
    let features: [Float]
}
enum Transform: String { case direct, log }
struct Candidate {
    let name: String, transform: Transform
    let train: (MLDataTable, MLDataTable, String, [String]) throws -> (MLModel, (URL, MLModelMetadata) throws -> Void)
}

func table(_ rows: [CachedPortionSample], target: String, transform: Transform, columns: [String]) -> MLDataTable {
    var result = MLDataTable()
    for column in columns {
        let index = Int(column.dropFirst())!
        result.addColumn(MLDataColumn(rows.map { Double($0.features[index]) }), named: column)
    }
    let values = rows.map { target == "grams" ? $0.grams : $0.calories }
    result.addColumn(MLDataColumn(values.map { transform == .log ? log($0) : $0 }), named: "output")
    return result
}
func provider(_ row: CachedPortionSample, columns: [String]) throws -> MLDictionaryFeatureProvider {
    try MLDictionaryFeatureProvider(dictionary: Dictionary(uniqueKeysWithValues: columns.map {
        ($0, Double(row.features[Int($0.dropFirst())!]))
    }))
}
func metrics(model: MLModel, rows: [CachedPortionSample], target: String, transform: Transform, columns: [String]) throws -> [String: Double] {
    var absolute = 0.0, squared = 0.0, percentage = 0.0
    for row in rows {
        let raw = try model.prediction(from: provider(row, columns: columns)).featureValue(for: "output")!.doubleValue
        let prediction = transform == .log ? exp(raw) : raw
        let truth = target == "grams" ? row.grams : row.calories
        let error = abs(max(1, prediction) - truth)
        absolute += error; squared += error * error; percentage += error / truth
    }
    let count = Double(rows.count)
    return ["mae": absolute/count, "rmse": sqrt(squared/count), "mape": percentage/count]
}

func strongestColumns(_ rows: [CachedPortionSample], target: String, count: Int) -> [String] {
    let targets = rows.map { target == "grams" ? $0.grams : $0.calories }
    let targetMean = targets.reduce(0, +) / Double(targets.count)
    return rows[0].features.indices.map { index -> (String, Double) in
        let values = rows.map { Double($0.features[index]) }
        let mean = values.reduce(0, +) / Double(values.count)
        let covariance = zip(values, targets).reduce(0.0) { $0 + ($1.0 - mean) * ($1.1 - targetMean) }
        let featureSS = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        return ("f\(index)", abs(covariance) / sqrt(max(featureSS, 1e-12)))
    }.sorted { $0.1 > $1.1 }.prefix(count).map(\.0)
}

@main struct TunePhotoPortion {
    static func main() throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard args.count == 3 || args.count == 4 else { fatalError("Usage: TunePhotoPortion cached-features.json new-output [feature-count]") }
        let featureCount = args.count == 4 ? Int(args[3]) ?? 192 : 192
        guard (1...768).contains(featureCount) else { fatalError("Feature count must be 1...768") }
        let samples = try JSONDecoder().decode([CachedPortionSample].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let grouped = Dictionary(grouping: samples, by: \.split)
        let train = grouped["train"]!, validation = grouped["validation"]!, test = grouped["test"]!
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var report: [String: Any] = ["train": train.count, "validation": validation.count, "test": test.count,
                                     "selection": "lowest validation MAE; held-out test used once after selection"]
        for target in ["grams", "calories"] {
            let columns = strongestColumns(train, target: target, count: featureCount)
            var candidates: [Candidate] = []
            for transform in [Transform.direct, .log] {
                for depth in [3, 5] {
                    for iterations in [120] {
                        let name = "boosted_\(transform.rawValue)_d\(depth)_i\(iterations)"
                        candidates.append(Candidate(name: name, transform: transform) { training, valid, _, features in
                            let parameters = MLBoostedTreeRegressor.ModelParameters(validation: .table(valid), maxDepth: depth,
                                maxIterations: iterations, randomSeed: 42, stepSize: 0.06, earlyStoppingRounds: 25,
                                rowSubsample: 0.85, columnSubsample: 0.85)
                            let model = try MLBoostedTreeRegressor(trainingData: training, targetColumn: "output", featureColumns: features, parameters: parameters)
                            return (model.model, { try model.write(to: $0, metadata: $1) })
                        })
                    }
                }
            }
            for transform in [Transform.direct, .log] {
                for depth in [10] {
                    let name = "forest_\(transform.rawValue)_d\(depth)_i250"
                    candidates.append(Candidate(name: name, transform: transform) { training, valid, _, features in
                        let parameters = MLRandomForestRegressor.ModelParameters(validationData: valid, maxDepth: depth,
                            maxIterations: 250, randomSeed: 42, rowSubsample: 0.85, columnSubsample: 0.85)
                        let model = try MLRandomForestRegressor(trainingData: training, targetColumn: "output", featureColumns: features, parameters: parameters)
                        return (model.model, { try model.write(to: $0, metadata: $1) })
                    })
                }
            }
            var results: [[String: Any]] = [], best: (Candidate, MLModel, (URL, MLModelMetadata) throws -> Void, Double)?
            for candidate in candidates {
                print("Training \(target) \(candidate.name)")
                let training = table(train, target: target, transform: candidate.transform, columns: columns)
                let valid = table(validation, target: target, transform: candidate.transform, columns: columns)
                let built = try candidate.train(training, valid, target, columns)
                let score = try metrics(model: built.0, rows: validation, target: target, transform: candidate.transform, columns: columns)
                results.append(["name": candidate.name, "transform": candidate.transform.rawValue, "validation": score])
                if best == nil || score["mae"]! < best!.3 { best = (candidate, built.0, built.1, score["mae"]!) }
            }
            let selected = best!
            let testMetrics = try metrics(model: selected.1, rows: test, target: target, transform: selected.0.transform, columns: columns)
            let modelURL = output.appendingPathComponent("Photo\(target.capitalized).mlmodel")
            try selected.2(modelURL, MLModelMetadata(author: "MealLens; Nutrition5k by Google Research",
                shortDescription: "Tuned \(target) prediction from Vision feature print revision 2.", version: "0.2",
                additional: ["data_source": "Nutrition5k", "data_license": "CC BY 4.0",
                             "target_transform": selected.0.transform.rawValue, "selected_candidate": selected.0.name]))
            report[target] = ["selected": selected.0.name, "transform": selected.0.transform.rawValue,
                              "validation_mae": selected.3, "test": testMetrics, "feature_columns": columns,
                              "candidates": results]
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("evaluation.json"))
    }
}
