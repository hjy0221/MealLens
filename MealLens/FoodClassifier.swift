import Foundation
import Vision
import CoreML
import ImageIO
import UniformTypeIdentifiers

struct FoodSuggestion: Identifiable, Sendable {
    static let soupChoicesID = "soup_choices"

    let id: String
    let label: String
    let confidence: Float
    let rawLabel: String
    private let matchedFoodID: String?

    var foods: [Food] {
        if id == Self.soupChoicesID { return FoodCatalog.soups }
        guard let matchedFoodID else { return [] }
        return FoodCatalog.foods.filter { $0.id == matchedFoodID }
    }

    var needsNutritionEntry: Bool { id != Self.soupChoicesID && matchedFoodID == nil }

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
    var regions: [ClassifiedFoodRegion] = []

    var estimatedItems: [MealItem] {
        guard regions.count > 1 else {
            return [PhotoCalorieEstimator.estimate(label: suggestions.first?.rawLabel, portion: portion)]
        }
        return RegionPortionAllocator.items(regions: regions, wholePlate: portion)
    }
}

protocol FoodClassifying: Sendable {
    func classify(_ photo: Data) async throws -> ClassificationResult
}

actor OnDeviceFoodClassifier: FoodClassifying {
    // The detector is intentionally broad and can outline empty plates or
    // bowls. Require a meaningful crop classification before creating a meal
    // item; otherwise an empty vessel becomes a false food entry.
    private static let regionConfidenceThreshold: Float = 0.45
    private static let identitySource = "Core ML · 한식 포함 기기 내 분석"
    private static let regionSource = "Core ML · 음식별 영역 분석"
    private static let bundledSource = "Core ML · 기기 내 분석"
    private static let visionSource = "Vision · 기기 내 분석"
    private static let bundledFallbackSource = "모델을 사용할 수 없어 Vision으로 분석"

    private var portionInference: PhotoPortionInference?
    private var identityInference: FoodIdentityInference?
    private var broadIdentityInference: FoodIdentityInference?
    private let detectorURL: URL?

    init(detectorURL: URL? = Bundle.main.url(forResource: "FoodDetector", withExtension: "mlmodelc")) {
        self.detectorURL = detectorURL
    }

    func classify(_ photo: Data) async throws -> ClassificationResult {
        var whole = try await classifyWhole(photo)
        // Only activate with a validated, explicitly supplied food detector.
        // Saliency finds objects, but cannot establish that each is food.
        guard let detectorURL else { return whole }
        do {
            let regions = try FoodRegionDetector(modelURL: detectorURL).detect(photo)
            guard regions.count > 1 else { return whole }
            var classified: [ClassifiedFoodRegion] = []
            for region in regions {
                try Task.checkCancellation()
                let crop = try FoodRegionDetector.crop(photo, box: region.box)
                let result = try await classifyWhole(crop, includePortion: false)
                // Keep uncertain detected foods instead of silently dropping
                // them and distributing their mass to confident predictions.
                let suggestion = result.suggestions.first
                guard let suggestion,
                      suggestion.confidence >= Self.regionConfidenceThreshold else { continue }
                classified.append(ClassifiedFoodRegion(box: region.box, label: suggestion.rawLabel))
            }
            // A detector may find bowls but no actual food. Keep the whole
            // photo estimate in that case instead of presenting empty items.
            guard classified.count > 1 else { return whole }
            whole.regions = classified
            whole = ClassificationResult(suggestions: whole.suggestions,
                source: Self.regionSource, portion: whole.portion, regions: classified)
        } catch is CancellationError { throw CancellationError() }
        catch { /* Detection failure keeps the existing whole-photo estimate. */ }
        return whole
    }

    private func classifyWhole(_ photo: Data, includePortion: Bool = true) async throws -> ClassificationResult {
        try Task.checkCancellation()
        if let url = Bundle.main.url(forResource: "FoodIdentity", withExtension: "mlmodelc") {
            do {
                let identityInference = try cachedIdentityInference(modelURL: url)
                let features = try PhotoFeatures.extract(photo)
                let detailedLabels = try identityInference.classify(features: features)
                let labels: [ImageLabel]
                if let broadURL = Bundle.main.url(forResource: "FoodBroadIdentity", withExtension: "mlmodelc"),
                   let broadLabels = try? cachedBroadIdentityInference(modelURL: broadURL).classify(features: features) {
                    labels = BroadFoodReconciler.reconcile(detailed: detailedLabels, broad: broadLabels)
                } else {
                    labels = detailedLabels
                }
                if includePortion && portionInference == nil { portionInference = try? PhotoPortionInference() }
                let portion = includePortion ? try? portionInference?.estimate(features: features) : nil
                try Task.checkCancellation()
                return ClassificationResult(suggestions: SuggestionResolver.resolve(labels),
                    source: Self.identitySource, portion: portion)
            } catch is CancellationError { throw CancellationError() }
            catch { /* The original bundled image model remains a fallback. */ }
        }
        let handler = VNImageRequestHandler(data: photo)
        var observations: [VNClassificationObservation] = []
        var labelMap: [String: String] = [:]
        var source = Self.visionSource
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
                source = Self.bundledSource
            } catch {
                source = Self.bundledFallbackSource
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
        if includePortion && portionInference == nil { portionInference = try? PhotoPortionInference() }
        let portion = includePortion ? try? portionInference?.estimate(photo) : nil
        try Task.checkCancellation()
        return ClassificationResult(suggestions: SuggestionResolver.resolve(observations.map {
            ImageLabel(identifier: labelMap[$0.identifier] ?? $0.identifier, confidence: $0.confidence)
        }), source: source, portion: portion)
    }

    private func cachedIdentityInference(modelURL: URL) throws -> FoodIdentityInference {
        if let identityInference { return identityInference }
        let inference = try FoodIdentityInference(modelURL: modelURL)
        identityInference = inference
        return inference
    }

    private func cachedBroadIdentityInference(modelURL: URL) throws -> FoodIdentityInference {
        if let broadIdentityInference { return broadIdentityInference }
        let inference = try FoodIdentityInference(modelURL: modelURL)
        broadIdentityInference = inference
        return inference
    }
}

enum BroadFoodReconciler {
    private static let deployable = Set(["hamburger", "pancake", "pasta", "pizza", "salad", "sandwich", "sushi"])
    private static let minimumConfidence: Float = 0.82

    static func reconcile(detailed: [ImageLabel], broad: [ImageLabel]) -> [ImageLabel] {
        guard let candidate = broad.first,
              candidate.confidence >= minimumConfidence,
              deployable.contains(FoodLabelFormatter.canonicalName(candidate.identifier)) else { return detailed }
        let broadName = FoodLabelFormatter.canonicalName(candidate.identifier)
        guard detailed.first.map({ FoodLabelFormatter.canonicalName($0.identifier) }) != broadName else { return detailed }
        return [candidate] + detailed.filter { FoodLabelFormatter.canonicalName($0.identifier) != broadName }
    }
}

struct ClassifiedFoodRegion: Sendable {
    /// Vision normalized coordinates, origin at bottom left.
    let box: CGRect
    let label: String?
}

struct FoodRegion: Sendable {
    let box: CGRect
    let confidence: Float
}

final class FoodRegionDetector {
    private static let minConfidence: Float = 0.4
    private static let minArea = 0.015
    private static let overlapThreshold = 0.5
    private static let maxRegions = 8
    private static let unitBox = CGRect(x: 0, y: 0, width: 1, height: 1)

    private let model: VNCoreMLModel

    init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try VNCoreMLModel(for: MLModel(contentsOf: modelURL, configuration: configuration))
    }

    func detect(_ photo: Data) throws -> [FoodRegion] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(data: photo).perform([request])
        guard let objects = request.results as? [VNRecognizedObjectObservation] else {
            throw CocoaError(.coderInvalidValue)
        }
        return Self.suppressOverlaps(objects.compactMap { object in
            guard let food = object.labels.first, food.identifier == "food" else { return nil }
            return FoodRegion(box: object.boundingBox, confidence: food.confidence)
        })
    }

    static func suppressOverlaps(_ candidates: [FoodRegion]) -> [FoodRegion] {
        var kept: [FoodRegion] = []
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            let raw = candidate.box
            guard [raw.origin.x, raw.origin.y, raw.width, raw.height].allSatisfy(\.isFinite),
                  raw.width > 0, raw.height > 0, candidate.confidence.isFinite,
                  candidate.confidence >= Self.minConfidence else { continue }
            let box = raw.intersection(Self.unitBox)
            guard !box.isNull, box.area >= Self.minArea else { continue }
            let overlaps = kept.contains { other in
                let intersection = box.intersection(other.box)
                let intersectionArea = intersection.isNull ? 0 : intersection.area
                let smallerArea = min(box.area, other.box.area)
                return intersectionArea / smallerArea > Self.overlapThreshold
            }
            if !overlaps { kept.append(FoodRegion(box: box, confidence: candidate.confidence)) }
            if kept.count == Self.maxRegions { break }
        }
        return kept.sorted { $0.box.midY == $1.box.midY ? $0.box.midX < $1.box.midX : $0.box.midY > $1.box.midY }
    }

    static func crop(_ photo: Data, box: CGRect) throws -> Data {
        guard let source = CGImageSourceCreateWithData(photo as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        // The caller supplies PhotoPreparation's orientation-normalized JPEG.
        let rect = CGRect(x: box.minX * Double(image.width), y: (1 - box.maxY) * Double(image.height),
                          width: box.width * Double(image.width), height: box.height * Double(image.height)).integral
        guard let cropped = image.cropping(to: rect) else { throw CocoaError(.fileReadCorruptFile) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}

private extension CGRect {
    var area: Double { Double(width * height) }
}

enum RegionPortionAllocator {
    static func items(regions: [ClassifiedFoodRegion], wholePlate: PhotoPortionEstimate?) -> [MealItem] {
        let areas = regions.map { max(0, $0.box.width * $0.box.height) }
        let totalArea = areas.reduce(0, +)
        var items = zip(regions, areas).map { region, area in
            var item = PhotoCalorieEstimator.estimate(label: region.label)
            if let wholePlate, wholePlate.isValid, totalArea.isFinite, totalArea > 0, area > 0 {
                // This is an area allocation, not a crop weight measurement.
                // Never apply a whole-plate regression independently per crop.
                item.grams = wholePlate.grams * area / totalArea
                item.estimateSource = "전체 추정 중량을 음식 영역 비율로 배분 · 추정"
            } else {
                item.estimateSource = "음식 영역 인식 · 대표량 추정"
            }
            return item
        }
        // Preserve the whole-photo energy estimate. Food identity determines
        // each item's relative energy share; the calorie model determines the
        // total, so multi-food analysis doesn't silently discard its output.
        if let wholePlate, wholePlate.isValid {
            let representativeTotal = items.reduce(0) { $0 + $1.calories }
            if representativeTotal.isFinite, representativeTotal > 0 {
                let scale = wholePlate.calories / representativeTotal
                for index in items.indices {
                    items[index].calories *= scale
                    items[index].estimateSource = "사진 전체 추정치를 음식 영역별로 배분 · 추정"
                }
            }
        }
        return items
    }
}

final class FoodIdentityInference {
    private let model: MLModel
    private let mapping: [String: String]
    private let probabilityName: String
    var labels: [String] { Array(mapping.values) }

    init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        guard let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
              let json = metadata["food_label_map"]?.data(using: .utf8),
              let probability = model.modelDescription.predictedProbabilitiesName else { throw CocoaError(.coderInvalidValue) }
        mapping = try JSONDecoder().decode([String: String].self, from: json)
        probabilityName = probability
    }

    func classify(features: [Float]) throws -> [ImageLabel] {
        let prediction = try model.prediction(from: PhotoFeatures.provider(features))
        guard let probabilities = prediction.featureValue(for: probabilityName)?.dictionaryValue else { throw CocoaError(.coderInvalidValue) }
        let labels = probabilities.compactMap { key, value -> ImageLabel? in
            guard let key = key as? String, let label = mapping[key], value.doubleValue.isFinite else { return nil }
            return ImageLabel(identifier: label, confidence: value.floatValue)
        }.sorted { $0.confidence > $1.confidence }
        guard !labels.isEmpty else { throw CocoaError(.coderInvalidValue) }
        return labels
    }
}

struct ImageLabel: Sendable {
    let identifier: String
    let confidence: Float
}

enum SuggestionResolver {
    private static let minimumConfidence: Float = 0.1
    private static let maximumSuggestions = 5
    private static let genericLabels: Set<String> = ["food", "foods", "dish", "meal", "plate", "menu", "container"]
    private static let soupChoiceLabels: Set<String> = ["soup", "soups", "stew"]

    static func resolve(_ labels: [ImageLabel]) -> [FoodSuggestion] {
        var seen = Set<String>()
        return Array(labels.sorted { $0.confidence > $1.confidence }.compactMap { label -> FoodSuggestion? in
            guard label.confidence.isFinite, label.confidence >= minimumConfidence else { return nil }
            let normalized = label.identifier.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !genericLabels.contains(normalized) else { return nil }
            // A broad soup observation is a choice of recipes, never a specific dish prediction.
            if soupChoiceLabels.contains(normalized) {
                guard seen.insert(FoodSuggestion.soupChoicesID).inserted else { return nil }
                return FoodSuggestion(id: FoodSuggestion.soupChoicesID, label: "국·수프 후보 · 종류를 골라주세요", confidence: label.confidence, rawLabel: label.identifier)
            }
            if let food = FoodCatalog.match(label.identifier) {
                guard seen.insert(food.id).inserted else { return nil }
                return FoodSuggestion(id: food.id, label: food.name, confidence: label.confidence, rawLabel: label.identifier, matchedFoodID: food.id)
            }
            let key = "model:" + normalized.replacingOccurrences(of: " ", with: "_")
            guard seen.insert(key).inserted else { return nil }
            return FoodSuggestion(id: key, label: "모델 후보 · \(FoodLabelFormatter.displayName(label.identifier))", confidence: label.confidence, rawLabel: label.identifier)
        }.prefix(maximumSuggestions))
    }
}

enum FoodLabelFormatter {
    // A whole-photo classifier cannot establish ingredients or whether a
    // plate contains only one type. Use family names for these mixed dishes.
    static func photoLabel(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        let key = canonicalName(identifier)
        if ["beet salad", "caesar salad", "caprese salad", "greek salad", "seaweed salad", "salad"].contains(key) {
            return "salad"
        }
        if ["onion rings", "fried calamari", "tempura", "고추튀김", "새우튀김", "오징어튀김"].contains(key) {
            return "fried foods"
        }
        return identifier
    }
    static func canonicalName(_ identifier: String) -> String {
        let sourceFree = identifier.split(separator: "__", maxSplits: 1, omittingEmptySubsequences: true).last.map(String.init) ?? identifier
        return sourceFree.precomposedStringWithCanonicalMapping.lowercased()
            .replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static let names: [String: String] = [
        "french_fries": "감자튀김", "ice_cream": "아이스크림", "pizza": "피자",
        "hamburger": "햄버거", "sushi": "초밥", "ramen": "라멘",
        "spaghetti_bolognese": "스파게티 볼로네제", "steak": "스테이크",
        "fried_rice": "볶음밥", "dumplings": "만두", "miso_soup": "미소된장국",
        "apple_pie": "애플파이", "baby_back_ribs": "돼지 등갈비", "baklava": "바클라바",
        "beef_carpaccio": "소고기 카르파초", "beef_tartare": "소고기 타르타르", "beet_salad": "비트 샐러드",
        "beignets": "베녜", "bibimbap": "비빔밥", "bread_pudding": "브레드 푸딩",
        "breakfast_burrito": "브렉퍼스트 부리토", "bruschetta": "브루스케타", "caesar_salad": "시저 샐러드",
        "cannoli": "카놀리", "caprese_salad": "카프레제 샐러드", "carrot_cake": "당근 케이크",
        "ceviche": "세비체", "cheesecake": "치즈케이크", "cheese_plate": "치즈 플래터",
        "chicken_curry": "치킨 커리", "chicken_quesadilla": "치킨 케사디야", "chicken_wings": "닭날개",
        "chocolate_cake": "초콜릿 케이크", "chocolate_mousse": "초콜릿 무스", "churros": "추로스",
        "clam_chowder": "클램 차우더", "club_sandwich": "클럽 샌드위치", "crab_cakes": "크랩 케이크",
        "creme_brulee": "크렘 브륄레", "croque_madame": "크로크 마담", "cup_cakes": "컵케이크",
        "deviled_eggs": "데빌드 에그", "donuts": "도넛", "edamame": "에다마메",
        "eggs_benedict": "에그 베네딕트", "escargots": "에스카르고", "falafel": "팔라펠",
        "filet_mignon": "안심 스테이크", "fish_and_chips": "피시 앤드 칩스", "foie_gras": "푸아그라",
        "french_onion_soup": "프렌치 어니언 수프", "french_toast": "프렌치토스트", "fried_calamari": "오징어튀김",
        "frozen_yogurt": "프로즌 요거트", "garlic_bread": "마늘빵", "gnocchi": "뇨키",
        "greek_salad": "그리스식 샐러드", "grilled_cheese_sandwich": "구운 치즈 샌드위치", "grilled_salmon": "연어구이",
        "guacamole": "과카몰리", "gyoza": "교자", "hot_and_sour_soup": "산라탕",
        "hot_dog": "핫도그", "huevos_rancheros": "우에보스 란체로스", "hummus": "후무스",
        "lasagna": "라자냐", "lobster_bisque": "로브스터 비스크", "lobster_roll_sandwich": "로브스터 롤 샌드위치",
        "macaroni_and_cheese": "마카로니 앤드 치즈", "macarons": "마카롱", "mussels": "홍합 요리",
        "nachos": "나초", "omelette": "오믈렛", "onion_rings": "어니언 링",
        "oysters": "굴", "pad_thai": "팟타이", "paella": "파에야", "pancakes": "팬케이크",
        "panna_cotta": "판나코타", "peking_duck": "베이징덕", "pho": "쌀국수",
        "pork_chop": "돼지 등심 스테이크", "poutine": "푸틴", "prime_rib": "프라임 립",
        "pulled_pork_sandwich": "풀드포크 샌드위치", "ravioli": "라비올리", "red_velvet_cake": "레드벨벳 케이크",
        "risotto": "리소토", "samosa": "사모사", "sashimi": "생선회", "scallops": "가리비 요리",
        "seaweed_salad": "해초 샐러드", "shrimp_and_grits": "새우와 그리츠", "spaghetti_carbonara": "스파게티 카르보나라",
        "spring_rolls": "춘권", "strawberry_shortcake": "딸기 쇼트케이크", "tacos": "타코",
        "takoyaki": "타코야키", "tiramisu": "티라미수", "tuna_tartare": "참치 타르타르", "waffles": "와플",
        "tteokbokki": "떡볶이", "soup": "국·수프", "stew": "찌개", "rice": "밥", "chicken": "닭고기",
        "egg": "달걀", "banana": "바나나", "apple": "사과", "bread": "빵", "salmon": "연어",
        "broccoli": "브로콜리", "tofu": "두부", "potato": "감자",
        "salad": "샐러드", "fried_foods": "튀김류", "tempura": "튀김류", "gyukatsu": "규카츠", "gyu_katsu": "규카츠",
        "pancake": "팬케이크", "pasta": "파스타", "sandwich": "샌드위치"
    ]

    static func displayName(_ identifier: String) -> String {
        // Training keeps source prefixes (for example food101__pizza) to
        // prevent accidental label collisions. Hide that implementation
        // detail when showing a candidate in the app.
        let sourceFree = identifier.split(separator: "__", maxSplits: 1, omittingEmptySubsequences: true).last.map(String.init) ?? identifier
        let normalized = sourceFree.precomposedStringWithCanonicalMapping
        let key = canonicalName(normalized).replacingOccurrences(of: " ", with: "_")
        return names[key] ?? (normalized.range(of: "[가-힣]", options: .regularExpression) != nil ? normalized : "음식")
    }

    static func storedName(_ name: String) -> String {
        let parts = name.components(separatedBy: " · ")
        let key = canonicalName(parts[0]).replacingOccurrences(of: " ", with: "_")
        guard let translated = names[key] else { return name }
        return ([translated] + parts.dropFirst()).joined(separator: " · ")
    }
}

enum PhotoPreparation {
    private static let maxPixelSize = 1600
    private static let compressionQuality = 0.8

    // Downsample and apply EXIF orientation without decoding a full-resolution image.
    // Re-encoding excludes original location metadata.
    static func prepare(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}
