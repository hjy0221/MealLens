import Foundation
import Vision
import CoreML
import ImageIO
import UniformTypeIdentifiers

struct FoodSuggestion: Identifiable, Sendable {
    let id: String
    let label: String
    let confidence: Float
    let rawLabel: String
    private let matchedFoodID: String?
    var foods: [Food] {
        if id == "soup_choices" { return FoodCatalog.soups }
        guard let matchedFoodID else { return [] }
        return FoodCatalog.foods.filter { $0.id == matchedFoodID }
    }
    var needsNutritionEntry: Bool { id != "soup_choices" && matchedFoodID == nil }

    init(id: String, label: String, confidence: Float, rawLabel: String = "", matchedFoodID: String? = nil) {
        self.id = id
        self.label = label
        self.confidence = confidence
        self.rawLabel = rawLabel.isEmpty ? label : rawLabel
        self.matchedFoodID = matchedFoodID
    }
}
struct ClassificationResult: Sendable {
    let suggestions: [FoodSuggestion]
    let source: String
    var portion: PhotoPortionEstimate? = nil
}
protocol FoodClassifying: Sendable {
    func classify(_ photo: Data) async throws -> ClassificationResult
}

actor OnDeviceFoodClassifier: FoodClassifying {
    private var portionInference: PhotoPortionInference?
    func classify(_ photo: Data) async throws -> ClassificationResult {
        try Task.checkCancellation()
        let handler = VNImageRequestHandler(data: photo)
        var observations: [VNClassificationObservation] = []
        var labelMap: [String: String] = [:]
        var source = "Vision · 기기 내 분석"
        if let url = Bundle.main.url(forResource: "FoodClassifier", withExtension: "mlmodelc") {
            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .all
                let coreModel = try MLModel(contentsOf: url, configuration: configuration)
                let metadata = coreModel.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
                let model = try VNCoreMLModel(for: coreModel)
                let request = VNCoreMLRequest(model: model)
                request.imageCropAndScaleOption = .centerCrop
                try handler.perform([request])
                guard let results = request.results as? [VNClassificationObservation] else {
                    throw CocoaError(.coderInvalidValue)
                }
                observations = results
                if let json = metadata?["food_label_map"]?.data(using: .utf8) {
                    labelMap = (try? JSONDecoder().decode([String: String].self, from: json)) ?? [:]
                }
                source = "Core ML · 기기 내 분석"
            } catch {
                source = "모델을 사용할 수 없어 Vision으로 분석"
                let request = VNClassifyImageRequest()
                try handler.perform([request])
                observations = request.results ?? []
            }
        } else {
            let request = VNClassifyImageRequest()
            try handler.perform([request])
            observations = request.results ?? []
        }
        try Task.checkCancellation()
        if portionInference == nil { portionInference = try? PhotoPortionInference() }
        let portion = try? portionInference?.estimate(photo)
        try Task.checkCancellation()
        return ClassificationResult(suggestions: SuggestionResolver.resolve(observations.map {
            ImageLabel(identifier: labelMap[$0.identifier] ?? $0.identifier, confidence: $0.confidence)
        }), source: source, portion: portion)
    }
}

struct ImageLabel {
    let identifier: String
    let confidence: Float
}

enum SuggestionResolver {
    private static let genericLabels: Set<String> = ["food", "foods", "dish", "meal", "plate", "menu", "container"]

    static func resolve(_ labels: [ImageLabel]) -> [FoodSuggestion] {
        var seen = Set<String>()
        return Array(labels.sorted { $0.confidence > $1.confidence }.compactMap { label -> FoodSuggestion? in
            guard label.confidence.isFinite, label.confidence >= 0.1 else { return nil }
            let normalized = label.identifier.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !genericLabels.contains(normalized) else { return nil }
            // A broad soup observation is a choice of recipes, never a specific dish prediction.
            if ["soup", "soups", "stew"].contains(normalized) {
                guard seen.insert("soup_choices").inserted else { return nil }
                return FoodSuggestion(id: "soup_choices", label: "국·수프 후보 · 종류를 골라주세요", confidence: label.confidence, rawLabel: label.identifier)
            }
            if let food = FoodCatalog.match(label.identifier) {
                guard seen.insert(food.id).inserted else { return nil }
                return FoodSuggestion(id: food.id, label: food.name, confidence: label.confidence, rawLabel: label.identifier, matchedFoodID: food.id)
            }
            let key = "model:" + normalized.replacingOccurrences(of: " ", with: "_")
            guard seen.insert(key).inserted else { return nil }
            return FoodSuggestion(id: key, label: "모델 후보 · \(FoodLabelFormatter.displayName(label.identifier))", confidence: label.confidence, rawLabel: label.identifier)
        }.prefix(5))
    }
}

enum FoodLabelFormatter {
    static func canonicalName(_ identifier: String) -> String {
        let sourceFree = identifier.split(separator: "__", maxSplits: 1, omittingEmptySubsequences: true).last.map(String.init) ?? identifier
        return sourceFree.precomposedStringWithCanonicalMapping.lowercased()
            .replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static let names: [String: String] = [
        "french_fries": "감자튀김", "ice_cream": "아이스크림", "pizza": "피자",
        "hamburger": "햄버거", "sushi": "초밥", "ramen": "라멘",
        "spaghetti_bolognese": "스파게티 볼로네제", "steak": "스테이크",
        "fried_rice": "볶음밥", "dumplings": "만두", "miso_soup": "미소된장국"
    ]

    static func displayName(_ identifier: String) -> String {
        // Training keeps source prefixes (for example food101__pizza) to
        // prevent accidental label collisions. Hide that implementation
        // detail when showing a candidate in the app.
        let sourceFree = identifier.split(separator: "__", maxSplits: 1, omittingEmptySubsequences: true).last.map(String.init) ?? identifier
        let key = sourceFree.lowercased().replacingOccurrences(of: " ", with: "_")
        return names[key] ?? sourceFree.replacingOccurrences(of: "_", with: " ")
    }
}

enum PhotoPreparation {
    // Downsample and apply EXIF orientation without decoding a full-resolution image.
    // Re-encoding excludes original location metadata.
    static func prepare(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}
