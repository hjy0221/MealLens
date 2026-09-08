import Foundation
import Vision
import CoreML

struct PhotoPortionEstimate: Sendable {
    private static let gramRange = 1.0...5000.0
    private static let calorieRange = 0.0...10000.0
    private static let maxCaloriesPer100g = 1000.0

    let grams: Double
    let calories: Double

    var isValid: Bool {
        grams.isFinite &&
        calories.isFinite &&
        Self.gramRange.contains(grams) &&
        calories > Self.calorieRange.lowerBound &&
        calories <= Self.calorieRange.upperBound &&
        calories / grams * 100 <= Self.maxCaloriesPer100g
    }
}

/// Nutrition5k RGB experiment. These models predict a whole plate's totals;
/// they do not segment foods or measure weight. Never apply to every item.
final class PhotoPortionInference {
    private struct PortionModel {
        let model: MLModel
        let outputName: String
        let usesLogTransform: Bool

        init(url: URL, configuration: MLModelConfiguration) throws {
            model = try MLModel(contentsOf: url, configuration: configuration)
            guard let predictedName = model.modelDescription.predictedFeatureName else {
                throw CocoaError(.coderInvalidValue)
            }
            outputName = predictedName
            let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
            usesLogTransform = metadata?["target_transform"] != "direct"
        }

        func value(from provider: MLFeatureProvider) throws -> Double {
            guard let raw = try model.prediction(from: provider).featureValue(for: outputName)?.doubleValue else {
                throw CocoaError(.coderInvalidValue)
            }
            return usesLogTransform ? exp(raw) : raw
        }
    }

    private let gramsModel: PortionModel
    private let caloriesModel: PortionModel

    convenience init(bundle: Bundle = .main) throws {
        guard let grams = bundle.url(forResource: "PhotoGrams", withExtension: "mlmodelc"),
              let calories = bundle.url(forResource: "PhotoCalories", withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        try self.init(gramsURL: grams, caloriesURL: calories)
    }

    init(gramsURL: URL, caloriesURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        gramsModel = try PortionModel(url: gramsURL, configuration: configuration)
        caloriesModel = try PortionModel(url: caloriesURL, configuration: configuration)
    }

    func estimate(_ photo: Data) throws -> PhotoPortionEstimate {
        try estimate(features: PhotoFeatures.extract(photo))
    }

    func estimate(features: [Float]) throws -> PhotoPortionEstimate {
        let provider = try PhotoFeatures.provider(features)
        let estimate = PhotoPortionEstimate(grams: try gramsModel.value(from: provider),
                                            calories: try caloriesModel.value(from: provider))
        guard estimate.isValid else { throw CocoaError(.coderInvalidValue) }
        return estimate
    }
}

/// Shared by on-device inference and the local classifier trainer.
enum PhotoFeatures {
    private static let expectedCount = 768

    static func extract(_ photo: Data) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .centerCrop
        #if targetEnvironment(simulator)
        // Older simulator runtimes cannot create the GPU inference context.
        // Keep the same revision and inputs while executing on the CPU.
        request.usesCPUOnly = true
        #endif
        try VNImageRequestHandler(data: photo).perform([request])
        guard let result = request.results?.first, result.elementType == .float, result.elementCount == expectedCount else {
            throw CocoaError(.coderInvalidValue)
        }
        let features = result.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        try validate(features)
        return features
    }

    static func provider(_ features: [Float]) throws -> MLDictionaryFeatureProvider {
        try validate(features)
        let inputs = Dictionary(uniqueKeysWithValues: features.enumerated().map { ("f\($0.offset)", Double($0.element)) })
        return try MLDictionaryFeatureProvider(dictionary: inputs)
    }

    private static func validate(_ features: [Float]) throws {
        guard features.count == expectedCount, features.allSatisfy(\.isFinite) else {
            throw CocoaError(.coderInvalidValue)
        }
    }
}
