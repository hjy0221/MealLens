import Foundation
import Vision
import CoreML

struct PhotoPortionEstimate: Sendable {
    let grams: Double
    let calories: Double
    var isValid: Bool {
        grams.isFinite && calories.isFinite && grams >= 1 && grams <= 5000 &&
        calories > 0 && calories <= 10000 && calories / grams * 100 <= 1000
    }
}

/// Nutrition5k RGB experiment. These models predict a whole plate's totals;
/// they do not segment foods or measure weight. Never apply to every item.
final class PhotoPortionInference {
    private let gramsModel: MLModel
    private let caloriesModel: MLModel

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
        gramsModel = try MLModel(contentsOf: gramsURL, configuration: configuration)
        caloriesModel = try MLModel(contentsOf: caloriesURL, configuration: configuration)
    }

    func estimate(_ photo: Data) throws -> PhotoPortionEstimate {
        try estimate(features: PhotoFeatures.extract(photo))
    }

    func estimate(features: [Float]) throws -> PhotoPortionEstimate {
        let provider = try PhotoFeatures.provider(features)
        let mass = try gramsModel.prediction(from: provider)
        let energy = try caloriesModel.prediction(from: provider)
        guard let logGrams = mass.featureValue(for: "log_grams")?.doubleValue,
              let logCalories = energy.featureValue(for: "log_calories")?.doubleValue else { throw CocoaError(.coderInvalidValue) }
        let estimate = PhotoPortionEstimate(grams: exp(logGrams), calories: exp(logCalories))
        guard estimate.isValid else { throw CocoaError(.coderInvalidValue) }
        return estimate
    }
}

/// Shared by on-device inference and the local classifier trainer.
enum PhotoFeatures {
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
        guard let result = request.results?.first, result.elementType == .float, result.elementCount == 768 else {
            throw CocoaError(.coderInvalidValue)
        }
        let features = result.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard features.count == 768, features.allSatisfy(\.isFinite) else { throw CocoaError(.coderInvalidValue) }
        return features
    }

    static func provider(_ features: [Float]) throws -> MLDictionaryFeatureProvider {
        guard features.count == 768, features.allSatisfy(\.isFinite) else { throw CocoaError(.coderInvalidValue) }
        let inputs = Dictionary(uniqueKeysWithValues: features.enumerated().map { ("f\($0.offset)", Double($0.element)) })
        return try MLDictionaryFeatureProvider(dictionary: inputs)
    }
}
