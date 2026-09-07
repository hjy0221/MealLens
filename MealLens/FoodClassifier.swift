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
    private var identityInference: FoodIdentityInference?
    func classify(_ photo: Data) async throws -> ClassificationResult {
        try Task.checkCancellation()
        if let url = Bundle.main.url(forResource: "FoodIdentity", withExtension: "mlmodelc") {
            do {
                if identityInference == nil { identityInference = try FoodIdentityInference(modelURL: url) }
                let features = try PhotoFeatures.extract(photo)
                let labels = try identityInference!.classify(features: features)
                if portionInference == nil { portionInference = try? PhotoPortionInference() }
                let portion = try? portionInference?.estimate(features: features)
                try Task.checkCancellation()
                return ClassificationResult(suggestions: SuggestionResolver.resolve(labels),
                    source: "Core ML · 한식 포함 기기 내 분석", portion: portion)
            } catch is CancellationError { throw CancellationError() }
            catch { /* The original bundled image model remains a fallback. */ }
        }
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

final class FoodIdentityInference {
    private let model: MLModel
    private let mapping: [String: String]
    private let probabilityName: String
    var labels: [String] { Array(mapping.values) }

    init(modelURL: URL) throws {
        let configuration = MLModelConfiguration(); configuration.computeUnits = .all
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
        "salad": "샐러드", "fried_foods": "튀김류", "tempura": "튀김류"
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
