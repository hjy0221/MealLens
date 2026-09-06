import Foundation
import CoreML

@main enum EvaluatePhotoPortion {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("EvaluatePhotoPortion <nutrition5k> <run-directory> <output-report>") }
        let root = URL(fileURLWithPath: args[1]), run = URL(fileURLWithPath: args[2])
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: run.appendingPathComponent("evaluation.json"))) as! [String: Any]
        let metrics = original["metrics"] as! [String: [String: Any]]
        let truths = Dictionary(uniqueKeysWithValues: (metrics["calories"]!["predictions"] as! [[String: Any]]).map { ($0["id"] as! String, $0["actual"] as! Double) })
        let rows = metrics["grams"]!["predictions"] as! [[String: Any]]
        let model = try PhotoPortionInference(
            gramsURL: MLModel.compileModel(at: run.appendingPathComponent("PhotoGrams.mlmodel")),
            caloriesURL: MLModel.compileModel(at: run.appendingPathComponent("PhotoCalories.mlmodel")))
        var predictions: [[String: Any]] = []
        var massError = 0.0, energyError = 0.0
        for row in rows {
            try autoreleasepool {
                let id = row["id"] as! String, grams = row["actual"] as! Double, calories = truths[id]!
                let data = try Data(contentsOf: root.appendingPathComponent("imagery/realsense_overhead/\(id)/rgb.png"))
                // Compile this executable with the actual app source files.
                let estimate = try model.estimate(PhotoPreparation.prepare(data))
                massError += abs(estimate.grams - grams); energyError += abs(estimate.calories - calories)
                predictions.append(["id": id, "actual_grams": grams, "actual_calories": calories,
                    "predicted_grams": estimate.grams, "predicted_calories": estimate.calories])
            }
            if predictions.count % 100 == 0 { print("App pipeline evaluated \(predictions.count)/\(rows.count)"); fflush(stdout) }
        }
        let report: [String: Any] = ["test_count": rows.count, "grams_mae": massError / Double(rows.count),
            "calories_mae": energyError / Double(rows.count), "predictions": predictions,
            "pipeline": "Unmodified app PhotoPreparation.prepare -> PhotoPortionInference.estimate, running on macOS",
            "limitations": "Same Nutrition5k holdout; no new smartphone or Korean validation photos"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[3]))
        print("App pipeline MAE: \(massError/Double(rows.count))g; \(energyError/Double(rows.count))kcal")
    }
}
