import XCTest
import SwiftData
import UIKit
import CoreML
@testable import MealLens

final class MealLensTests: XCTestCase {
    func testBroadClassifierOnlyOverridesWithStrongSpecificEvidence() {
        let detailed = [ImageLabel(identifier: "food101__bibimbap", confidence: 0.72)]
        XCTAssertEqual(BroadFoodReconciler.reconcile(detailed: detailed,
            broad: [ImageLabel(identifier: "openimages__pizza", confidence: 0.9)]).first?.identifier,
            "openimages__pizza")
        XCTAssertEqual(BroadFoodReconciler.reconcile(detailed: detailed,
            broad: [ImageLabel(identifier: "openimages__pizza", confidence: 0.7)]).first?.identifier,
            "food101__bibimbap")
    }

    func testGyukatsuIsAvailableAsAnExplicitFoodChoice() {
        let food = FoodCatalog.match("gyukatsu")
        XCTAssertEqual(food?.name, "규카츠")
        XCTAssertEqual(FoodLabelFormatter.displayName("gyukatsu"), "규카츠")
    }

    func testRegionAllocationPreservesWholePlateMassWithoutDuplicatingCalories() {
        let regions = [ClassifiedFoodRegion(box: CGRect(x: 0, y: 0, width: 0.4, height: 0.5), label: "rice"),
                       ClassifiedFoodRegion(box: CGRect(x: 0.5, y: 0, width: 0.2, height: 0.5), label: "pizza")]
        let items = RegionPortionAllocator.items(regions: regions, wholePlate: .init(grams: 450, calories: 700))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].grams, 300, accuracy: 0.001)
        XCTAssertEqual(items[1].grams, 150, accuracy: 0.001)
        XCTAssertEqual(items.reduce(0) { $0 + $1.grams }, 450, accuracy: 0.001)
        XCTAssertEqual(items.reduce(0) { $0 + $1.calories }, 700, accuracy: 0.001)
        XCTAssertTrue(items.allSatisfy(\.isValid))
        XCTAssertGreaterThan(items[1].calories, items[0].calories)
    }

    func testRegionSuppressionRemovesDuplicatesButRetainsSeparateSameFoods() {
        let boxes = [FoodRegion(box: CGRect(x: 0, y: 0, width: 0.4, height: 0.4), confidence: 0.9),
                     FoodRegion(box: CGRect(x: 0.01, y: 0.01, width: 0.4, height: 0.4), confidence: 0.8),
                     FoodRegion(box: CGRect(x: 0.6, y: 0, width: 0.4, height: 0.4), confidence: 0.8),
                     FoodRegion(box: CGRect(x: 0, y: 0.7, width: 0.2, height: 0.2), confidence: 0.1)]
        XCTAssertEqual(FoodRegionDetector.suppressOverlaps(boxes).count, 2)
    }

    func testRegionCropFlipsVisionVerticalCoordinates() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
        }
        let cropped = try FoodRegionDetector.crop(XCTUnwrap(image.jpegData(compressionQuality: 1)),
                                                  box: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        let result = try XCTUnwrap(UIImage(data: cropped)?.cgImage)
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 50)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(result, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[0], 200)
        XCTAssertLessThan(pixel[2], 50)
    }

    func testNewClassifierCoversKoreanFoodsAndValidatesFeatureShape() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "FoodIdentity", withExtension: "mlmodelc"))
        let model = try FoodIdentityInference(modelURL: url)
        XCTAssertEqual(model.labels.count, 251)
        XCTAssertTrue(model.labels.contains("aihub_korea__떡볶이"))
        XCTAssertTrue(model.labels.contains("aihub_korea__새우튀김"))
        XCTAssertTrue(model.labels.allSatisfy { FoodLabelFormatter.displayName($0) != "음식" })
        XCTAssertThrowsError(try model.classify(features: [0, 1]))
        let scores = try model.classify(features: Array(repeating: 0, count: 768))
        XCTAssertEqual(scores.count, 251)
        XCTAssertEqual(scores.reduce(0.0) { $0 + Double($1.confidence) }, 1, accuracy: 0.0001)
    }

    func testNewClassifierRunsThroughTheAppPipeline() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 384)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 384, height: 384))
            UIColor.brown.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 60, y: 60, width: 250, height: 250))
        }
        let data = try PhotoPreparation.prepare(XCTUnwrap(image.jpegData(compressionQuality: 0.8)))
        let result = try await OnDeviceFoodClassifier().classify(data)
        XCTAssertEqual(result.source, "Core ML · 한식 포함 기기 내 분석")
    }
    func testPhotoNamesDoNotAssertSaladOrFritterIngredients() {
        for label in ["food101__seaweed_salad", "food101__caesar_salad"] {
            let item = PhotoCalorieEstimator.estimate(label: label, portion: .init(grams: 140, calories: 110))
            XCTAssertTrue(item.name.hasPrefix("샐러드 ·"))
            XCTAssertEqual(item.calories, 110, accuracy: 0.001)
        }
        for label in ["food101__onion_rings", "aihub_korea__새우튀김", "tempura"] {
            XCTAssertTrue(PhotoCalorieEstimator.estimate(label: label).name.hasPrefix("튀김류 ·"))
        }
        XCTAssertTrue(PhotoCalorieEstimator.estimate(label: "pizza").name.hasPrefix("피자 ·"))
        // Manual naming and the underlying class translation keep their specificity.
        XCTAssertEqual(FoodLabelFormatter.displayName("food101__onion_rings"), "어니언 링")
    }
    func testAllBundledFoodLabelsHaveKoreanNames() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "FoodClassifier", withExtension: "mlmodelc"))
        let model = try MLModel(contentsOf: url)
        let labels = try XCTUnwrap(model.modelDescription.classLabels as? [String])
        XCTAssertEqual(labels.count, 101)
        for label in labels {
            let name = FoodLabelFormatter.displayName(label)
            XCTAssertNotEqual(name, "음식", label)
            XCTAssertNotNil(name.range(of: "[가-힣]", options: .regularExpression), label)
        }
        XCTAssertEqual(FoodLabelFormatter.storedName("bibimbap · 사진 기반 추정"), "비빔밥 · 사진 기반 추정")
        XCTAssertEqual(FoodLabelFormatter.storedName("엄마가 만든 점심"), "엄마가 만든 점심")
    }

    func testEditedCaloriesPersistAndScaleWithWeight() throws {
        var item = MealItem(food: FoodCatalog.foods[0], grams: 200)
        item.name = "내 볶음밥"
        item.calories = 420
        XCTAssertEqual(item.calories, 420, accuracy: 0.001)
        item.grams = 100
        XCTAssertEqual(item.calories, 210, accuracy: 0.001)
        let restored = try JSONDecoder().decode(MealItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.name, "내 볶음밥")
        XCTAssertEqual(restored.calories, 210, accuracy: 0.001)
        item.calories = -1
        XCTAssertFalse(item.isValid)
    }

    @MainActor func testPhotoBackupRestoreAndStoreReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("records.store")
        let config = ModelConfiguration(url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Meal.self, configurations: config)
        let context = ModelContext(container)
        let photo = Data(repeating: 0xAB, count: 256 * 1024)
        var item = MealItem(food: FoodCatalog.foods[0], grams: 250)
        item.calories = 430
        let meal = Meal(date: Date(), title: "사진이 있는 식사", items: [item], photo: photo)
        let archive = try JSONEncoder().encode(MealArchive(meals: [meal]))
        XCTAssertEqual(try MealArchive.restore(archive, into: context), 1)
        XCTAssertEqual(try MealArchive.restore(archive, into: context), 0)
        let reopened = try ModelContainer(for: Meal.self, configurations: config)
        let saved = try XCTUnwrap(ModelContext(reopened).fetch(FetchDescriptor<Meal>()).first)
        XCTAssertEqual(saved.photo, photo)
        XCTAssertEqual(saved.id, meal.id)
        XCTAssertEqual(saved.items[0].calories, 430, accuracy: 0.001)
        XCTAssertThrowsError(try MealArchive.restore(Data("{}".utf8), into: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Meal>()), 1)
    }
    func testPortionScalingAndMixedMeal() {
        let rice = MealItem(food: FoodCatalog.foods[0], grams: 200)
        let chicken = MealItem(food: FoodCatalog.foods[1], grams: 150)
        let total = rice.nutrients + chicken.nutrients
        XCTAssertEqual(total.calories, 507.5, accuracy: 0.01)
        XCTAssertEqual(total.protein, 51.9, accuracy: 0.01)
        XCTAssertEqual(total.carbs, 56.4, accuracy: 0.01)
    }
    func testInvalidPortions() {
        for grams in [0.0, -1, .nan, .infinity, 5001] { XCTAssertFalse(MealItem(food: FoodCatalog.foods[0], grams: grams).isValid) }
        XCTAssertTrue(MealItem(food: FoodCatalog.foods[0], grams: 0.5).isValid)
    }
    func testOnlyExplicitFoodAliasesMatch() {
        XCTAssertEqual(FoodCatalog.match("white_rice")?.id, "rice")
        XCTAssertNil(FoodCatalog.match("food"))
        XCTAssertNil(FoodCatalog.match("pineapple"))
        XCTAssertNil(FoodCatalog.match("fried chicken"))
    }
    func testKoreanTrainingLabelUsesExistingSoupNutrition() throws {
        // macOS folder labels may use decomposed Hangul; model labels also
        // retain dataset prefixes. Both must resolve to the same food.
        let label = "aihub_korea__미역국".decomposedStringWithCanonicalMapping
        let suggestion = try XCTUnwrap(SuggestionResolver.resolve([ImageLabel(identifier: label, confidence: 0.9)]).first)
        XCTAssertEqual(suggestion.foods.first?.id, "seaweed_soup")
        let estimate = PhotoCalorieEstimator.estimate(label: label)
        XCTAssertEqual(estimate.grams, 300)
        XCTAssertEqual(estimate.nutrients.calories, 75)
        XCTAssertEqual(FoodCatalog.match("food101__seaweed_soup")?.id, "seaweed_soup")
        XCTAssertNil(FoodCatalog.match("aihub_korea__된장찌개"))
    }
    func testSoupLabelOffersRecipeChoicesWithoutInventingADish() throws {
        let suggestions = SuggestionResolver.resolve([ImageLabel(identifier: "soup", confidence: 0.8)])
        let suggestion = try XCTUnwrap(suggestions.first)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestion.id, "soup_choices")
        XCTAssertEqual(Set(suggestion.foods.map(\.id)), Set(FoodCatalog.soupIDs))
        XCTAssertNil(FoodCatalog.match("soup"))
    }
    func testSoupChoicesDeduplicateAndRejectWeakLabels() {
        let suggestions = SuggestionResolver.resolve([
            ImageLabel(identifier: "soup", confidence: 0.8),
            ImageLabel(identifier: "stew", confidence: 0.6),
            ImageLabel(identifier: "banana", confidence: 0.01),
            ImageLabel(identifier: "food", confidence: 0.99)
        ])
        XCTAssertEqual(suggestions.map(\.id), ["soup_choices"])
        XCTAssertTrue(SuggestionResolver.resolve([ImageLabel(identifier: "soup", confidence: .nan)]).isEmpty)
    }
    func testGlobalModelLabelIsPreservedForManualNutritionEntry() throws {
        let suggestion = try XCTUnwrap(SuggestionResolver.resolve([
            ImageLabel(identifier: "sushi", confidence: 0.82)
        ]).first)
        XCTAssertTrue(suggestion.needsNutritionEntry)
        XCTAssertEqual(suggestion.rawLabel, "sushi")
        XCTAssertEqual(suggestion.label, "모델 후보 · 초밥")
        XCTAssertTrue(suggestion.foods.isEmpty)
    }
    func testPhotoOnlyEstimatorCreatesValidAutomaticEstimate() {
        let pizza = PhotoCalorieEstimator.estimate(label: "food101__pizza")
        XCTAssertEqual(pizza.grams, 180)
        XCTAssertEqual(pizza.nutrients.calories, 478.8, accuracy: 0.01)
        XCTAssertTrue(pizza.isValid)
        let unknown = PhotoCalorieEstimator.estimate(label: nil)
        XCTAssertTrue(unknown.isValid)
        XCTAssertGreaterThan(unknown.nutrients.calories, 0)
    }
    func testPhotoPredictionReplacesRepresentativeMassAndEnergy() {
        let item = PhotoCalorieEstimator.estimate(label: "food101__pizza", portion: .init(grams: 270, calories: 620))
        XCTAssertEqual(item.grams, 270)
        XCTAssertEqual(item.nutrients.calories, 620, accuracy: 0.001)
        XCTAssertEqual(item.estimateSource, "사진 기반 중량·열량 추정 · 실험")
        XCTAssertTrue(item.isValid)
        for bad in [PhotoPortionEstimate(grams: .nan, calories: 500), .init(grams: 0, calories: 300), .init(grams: 10, calories: .infinity)] {
            XCTAssertFalse(bad.isValid)
            XCTAssertEqual(PhotoCalorieEstimator.estimate(label: "pizza", portion: bad).grams, 180)
        }
    }
    func testBundledPortionModelsRunOnIOSAndRespondToImageContent() throws {
        // This checks runtime compatibility, not real-food accuracy. Both
        // fixtures are synthetic and contain no dataset images.
        func photo(_ large: Bool) throws -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 384), format: format)
            return try XCTUnwrap(renderer.image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 384, height: 384))
                UIColor.brown.setFill()
                context.cgContext.fillEllipse(in: large ? CGRect(x: 30,y: 30,width: 320,height: 320) : CGRect(x: 150,y: 150,width: 80,height: 80))
                UIColor.green.setFill(); context.fill(CGRect(x: 50,y: 80,width: 40,height: 100))
            }.jpegData(compressionQuality: 0.9))
        }
        let model = try PhotoPortionInference()
        let small = try model.estimate(PhotoPreparation.prepare(photo(false)))
        let large = try model.estimate(PhotoPreparation.prepare(photo(true)))
        XCTAssertTrue(small.isValid); XCTAssertTrue(large.isValid)
        XCTAssertGreaterThan(abs(small.grams - large.grams) + abs(small.calories - large.calories), 0.01)
    }
    func testMealItemsSavedBeforeEstimateSourceStillDecode() throws {
        let old = MealItem(food: FoodCatalog.foods[0])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "estimateSource")
        let decoded = try JSONDecoder().decode(MealItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.estimateSource)
        XCTAssertEqual(decoded.nutrients.calories, old.nutrients.calories)
    }
    func testSoupPortionCalculationAfterUserChoice() throws {
        let food = try XCTUnwrap(FoodCatalog.foods.first { $0.id == "seaweed_soup" })
        XCTAssertEqual(food.suggestedGrams, 300)
        let bowl = MealItem(food: food, grams: food.suggestedGrams)
        let half = MealItem(food: food, grams: 150)
        XCTAssertEqual(bowl.nutrients.calories, 75)
        XCTAssertEqual(half.nutrients.calories, 37.5)
        XCTAssertTrue(bowl.isValid)
        XCTAssertTrue(FoodCatalog.soups.allSatisfy { MealItem(food: $0, grams: $0.suggestedGrams).isValid })
    }
    func testDayBoundaryIncludingDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let entries = [start.addingTimeInterval(-1), start, end.addingTimeInterval(-1), end].map { Meal(date: $0, title: "Test", items: [], photo: nil) }
        XCTAssertEqual(DailySummary.meals(entries, on: date, calendar: calendar).count, 2)
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600)
    }
    @MainActor func testPersistenceUpdateAndDelete() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        defer { for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Meal.self, configurations: configuration)
        let context = ModelContext(container)
        let meal = Meal(date: Date(), title: "Lunch", items: [MealItem(food: FoodCatalog.foods[0], grams: 200)], photo: Data([1, 2, 3]))
        context.insert(meal); try context.save()
        let reloadedContainer = try ModelContainer(for: Meal.self, configurations: configuration)
        let fresh = ModelContext(reloadedContainer)
        let saved = try XCTUnwrap(fresh.fetch(FetchDescriptor<Meal>()).first)
        XCTAssertEqual(saved.total.calories, 260)
        XCTAssertEqual(saved.photo, Data([1, 2, 3]))
        saved.items = [MealItem(food: FoodCatalog.foods[0], grams: 100)]
        try fresh.save()
        XCTAssertEqual(saved.total.calories, 130)
        fresh.delete(saved); try fresh.save()
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Meal>()), 0)
    }
    func testCorruptImageFailsSafely() async {
        do { _ = try PhotoPreparation.prepare(Data([0, 1, 2])); XCTFail("Invalid image accepted") } catch { }
        do { _ = try await OnDeviceFoodClassifier().classify(Data([0, 1, 2])); XCTFail("Invalid image classified") } catch { }
    }
}
