import Foundation
import Vision
import CoreML
import ImageIO

private struct AnnotatedImage: Decodable {
    struct Annotation: Decodable {
        struct Coordinates: Decodable { let x, y, width, height: Double }
        let coordinates: Coordinates
    }
    let image: String
    let annotations: [Annotation]
}

private struct Counts {
    var truth = 0, predictions = 0, matches = 0, images = 0, complete = 0
    mutating func add(truth boxes: [CGRect], predictions proposed: [CGRect]) {
        images += 1; truth += boxes.count; predictions += proposed.count
        var unmatched = Set(boxes.indices)
        var found = 0
        for proposal in proposed {
            let best = unmatched.map { index -> (Int, Double) in
                let intersection = proposal.intersection(boxes[index])
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                let union = proposal.width * proposal.height + boxes[index].width * boxes[index].height - area
                return (index, union > 0 ? area / union : 0)
            }.max { $0.1 < $1.1 }
            if let best, best.1 >= 0.5 { unmatched.remove(best.0); found += 1 }
        }
        matches += found
        if found == boxes.count { complete += 1 }
    }
    var json: [String: Any] {
        ["images": images, "truth_boxes": truth, "predicted_boxes": predictions, "matched_boxes": matches,
         "precision_at_iou50": Double(matches) / Double(max(predictions, 1)),
         "recall_at_iou50": Double(matches) / Double(max(truth, 1)), "all_foods_found_images": complete]
    }
}

@main struct EvaluateFoodDetector {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 || args.count == 5 else { fatalError("Usage: evaluate model.mlmodel test-folder output.json [exclude-annotations.json]") }
        let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: args[1]))
        defer { try? FileManager.default.removeItem(at: compiled) }
        let detector = try FoodRegionDetector(modelURL: compiled)
        let root = URL(fileURLWithPath: args[2])
        var records = try JSONDecoder().decode([AnnotatedImage].self, from: Data(contentsOf: root.appendingPathComponent("annotations.json")))
        if args.count == 5 {
            let excluded = try JSONDecoder().decode([AnnotatedImage].self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
            let names = Set(excluded.map(\.image))
            records.removeAll { names.contains($0.image) }
        }
        var detectorAll = Counts(), detectorMulti = Counts(), saliencyAll = Counts(), saliencyMulti = Counts()
        var failures = 0
        for (index, record) in records.enumerated() {
            try autoreleasepool {
                let data = try Data(contentsOf: root.appendingPathComponent(record.image))
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
                let width = Double(image.width), height = Double(image.height)
                let truth = record.annotations.map { annotation -> CGRect in
                    let b = annotation.coordinates
                    return CGRect(x: (b.x-b.width/2)/width, y: 1-(b.y+b.height/2)/height,
                                  width: b.width/width, height: b.height/height)
                }
                let predictions = try detector.detect(data).map(\.box)
                let request = VNGenerateObjectnessBasedSaliencyImageRequest()
                var baseline: [CGRect] = []
                do {
                    try VNImageRequestHandler(data: data).perform([request])
                    baseline = request.results?.first?.salientObjects?.map(\.boundingBox) ?? []
                } catch { failures += 1 }
                detectorAll.add(truth: truth, predictions: predictions)
                saliencyAll.add(truth: truth, predictions: baseline)
                if truth.count > 1 {
                    detectorMulti.add(truth: truth, predictions: predictions)
                    saliencyMulti.add(truth: truth, predictions: baseline)
                }
            }
            if index % 50 == 0 { print("Evaluated \(index + 1)/\(records.count)") }
        }
        let report: [String: Any] = ["detector_all": detectorAll.json, "detector_multi": detectorMulti.json,
            "saliency_all": saliencyAll.json, "saliency_multi": saliencyMulti.json, "saliency_failures": failures,
            "confidence_threshold": 0.4, "iou_threshold": 0.5,
            "scope": "Food regions only; not food identity, grams or calorie accuracy. UEC noncommercial research."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[3]))
    }
}
