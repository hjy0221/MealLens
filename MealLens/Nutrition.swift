import Foundation
import SwiftData

struct Nutrients: Codable, Equatable {
    var calories = 0.0
    var protein = 0.0
    var carbs = 0.0
    var fat = 0.0
    func scaled(by factor: Double) -> Self {
        .init(calories: calories * factor, protein: protein * factor, carbs: carbs * factor, fat: fat * factor)
    }
    static func + (lhs: Self, rhs: Self) -> Self {
        .init(calories: lhs.calories + rhs.calories, protein: lhs.protein + rhs.protein,
              carbs: lhs.carbs + rhs.carbs, fat: lhs.fat + rhs.fat)
    }
}

struct Food: Identifiable, Codable {
    let id: String
    let name: String
    let aliases: [String]
    let per100g: Nutrients
    var suggestedGrams: Double { FoodCatalog.soupIDs.contains(id) ? 300 : 100 }
}

enum FoodCatalog {
    static let soupIDs = ["seaweed_soup", "doenjang_soup", "beef_radish_soup", "kimchi_stew"]
    static var soups: [Food] { foods.filter { soupIDs.contains($0.id) } }
    // Illustrative seed values, not a validated nutrition dataset. Replace before production.
    static let foods: [Food] = [
        Food(id: "rice", name: "쌀밥 · 조리됨", aliases: ["rice", "white rice"], per100g: .init(calories: 130, protein: 2.7, carbs: 28.2, fat: 0.3)),
        Food(id: "chicken", name: "닭가슴살 · 구움", aliases: ["chicken", "chicken breast"], per100g: .init(calories: 165, protein: 31, carbs: 0, fat: 3.6)),
        Food(id: "egg", name: "달걀 · 삶음", aliases: ["egg", "boiled egg"], per100g: .init(calories: 155, protein: 12.6, carbs: 1.1, fat: 10.6)),
        Food(id: "banana", name: "바나나", aliases: ["banana"], per100g: .init(calories: 89, protein: 1.1, carbs: 22.8, fat: 0.3)),
        Food(id: "apple", name: "사과", aliases: ["apple"], per100g: .init(calories: 52, protein: 0.3, carbs: 13.8, fat: 0.2)),
        Food(id: "salmon", name: "연어 · 구움", aliases: ["salmon"], per100g: .init(calories: 206, protein: 22, carbs: 0, fat: 12)),
        Food(id: "broccoli", name: "브로콜리 · 삶음", aliases: ["broccoli"], per100g: .init(calories: 35, protein: 2.4, carbs: 7.2, fat: 0.4)),
        Food(id: "bread", name: "식빵", aliases: ["bread", "toast"], per100g: .init(calories: 266, protein: 8.9, carbs: 49.4, fat: 3.3)),
        Food(id: "tofu", name: "두부", aliases: ["tofu"], per100g: .init(calories: 85, protein: 9, carbs: 2, fat: 5)),
        Food(id: "potato", name: "감자 · 삶음", aliases: ["potato"], per100g: .init(calories: 87, protein: 1.9, carbs: 20.1, fat: 0.1)),
        Food(id: "seaweed_soup", name: "미역국", aliases: ["seaweed soup", "miyeok guk", "미역국"], per100g: .init(calories: 25, protein: 1.9, carbs: 1.5, fat: 1.3)),
        Food(id: "doenjang_soup", name: "된장국", aliases: ["doenjang soup", "doenjang guk", "된장국"], per100g: .init(calories: 35, protein: 2.4, carbs: 3.2, fat: 1.4)),
        Food(id: "beef_radish_soup", name: "소고기뭇국", aliases: ["beef radish soup", "소고기뭇국"], per100g: .init(calories: 32, protein: 3, carbs: 1.5, fat: 1.5)),
        Food(id: "kimchi_stew", name: "김치찌개", aliases: ["kimchi stew", "kimchi jjigae", "김치찌개"], per100g: .init(calories: 55, protein: 4, carbs: 3, fat: 3))
    ]
    static func match(_ label: String) -> Food? {
        let normalized = FoodLabelFormatter.canonicalName(label)
        return foods.first {
            FoodLabelFormatter.canonicalName($0.id) == normalized ||
            $0.aliases.contains { FoodLabelFormatter.canonicalName($0) == normalized }
        }
    }
}

/// Converts food identity into a rough estimate using a representative serving.
/// This fallback does not infer portion size from image pixels.
enum PhotoCalorieEstimator {
    private static let values: [String: Nutrients] = [
        "apple pie": .init(calories: 237, protein: 2, carbs: 34, fat: 11),
        "bibimbap": .init(calories: 140, protein: 6, carbs: 19, fat: 4),
        "caesar salad": .init(calories: 160, protein: 7, carbs: 8, fat: 11),
        "chicken curry": .init(calories: 150, protein: 10, carbs: 8, fat: 9),
        "chicken wings": .init(calories: 290, protein: 23, carbs: 9, fat: 19),
        "chocolate cake": .init(calories: 370, protein: 5, carbs: 51, fat: 17),
        "dumplings": .init(calories: 200, protein: 8, carbs: 25, fat: 8),
        "french fries": .init(calories: 310, protein: 3, carbs: 41, fat: 15),
        "fried rice": .init(calories: 180, protein: 5, carbs: 26, fat: 6),
        "hamburger": .init(calories: 250, protein: 13, carbs: 20, fat: 14),
        "ice cream": .init(calories: 210, protein: 4, carbs: 24, fat: 11),
        "lasagna": .init(calories: 160, protein: 9, carbs: 15, fat: 8),
        "miso soup": .init(calories: 40, protein: 3, carbs: 4, fat: 1),
        "pizza": .init(calories: 266, protein: 11, carbs: 33, fat: 10),
        "ramen": .init(calories: 80, protein: 4, carbs: 10, fat: 3),
        "risotto": .init(calories: 170, protein: 4, carbs: 25, fat: 6),
        "sashimi": .init(calories: 140, protein: 24, carbs: 0, fat: 5),
        "spaghetti bolognese": .init(calories: 160, protein: 8, carbs: 20, fat: 6),
        "steak": .init(calories: 250, protein: 26, carbs: 0, fat: 16),
        "sushi": .init(calories: 150, protein: 7, carbs: 25, fat: 3),
        "tacos": .init(calories: 200, protein: 10, carbs: 20, fat: 9),
        "waffles": .init(calories: 290, protein: 8, carbs: 33, fat: 14)
    ]

    static func estimate(label: String?, portion: PhotoPortionEstimate? = nil) -> MealItem {
        var item = representativeEstimate(label: label)
        if let portion, portion.isValid {
            item.grams = portion.grams
            item.per100g.calories = portion.calories / portion.grams * 100
            item.estimateSource = "사진 기반 중량·열량 추정 · 실험"
        } else {
            item.estimateSource = "음식별 대표량으로 계산"
        }
        return item
    }

    private static func representativeEstimate(label: String?) -> MealItem {
        let original = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let food = FoodCatalog.match(original) {
            return MealItem(name: "\(food.name) · 추정", grams: food.suggestedGrams, per100g: food.per100g)
        }
        let sourceFree = original.split(separator: "__", maxSplits: 1, omittingEmptySubsequences: true).last.map(String.init) ?? original
        let normalized = sourceFree.lowercased().replacingOccurrences(of: "_", with: " ")
        let nutrients = values[normalized] ?? fallback(for: normalized)
        let grams = servingGrams(for: normalized)
        let display = original.isEmpty ? "음식" : FoodLabelFormatter.displayName(sourceFree)
        return MealItem(name: "\(display) · 사진 기반 추정", grams: grams, per100g: nutrients)
    }

    private static func servingGrams(for label: String) -> Double {
        if ["soup", "stew", "broth", "ramen", "pho", "chowder"].contains(where: { label.contains($0) }) { return 300 }
        if label.contains("pizza") { return 180 }
        if ["hamburger", "burger", "hot dog", "sandwich", "burrito"].contains(where: { label.contains($0) }) { return 200 }
        if ["steak", "beef", "pork", "chicken", "lamb", "salmon", "fish"].contains(where: { label.contains($0) }) { return 180 }
        if ["sushi", "dumpling", "taco", "nachos"].contains(where: { label.contains($0) }) { return 200 }
        if ["salad", "vegetable", "fruit"].contains(where: { label.contains($0) }) { return 200 }
        if ["rice", "pasta", "spaghetti", "lasagna", "risotto"].contains(where: { label.contains($0) }) { return 250 }
        if ["cake", "dessert", "ice cream", "donut", "chocolate", "cookie", "pie"].contains(where: { label.contains($0) }) { return 120 }
        return 150
    }

    private static func fallback(for label: String) -> Nutrients {
        if ["soup", "stew", "broth", "salad", "fruit", "vegetable"].contains(where: { label.contains($0) }) {
            return .init(calories: 80, protein: 3, carbs: 10, fat: 3)
        }
        if ["cake", "dessert", "ice cream", "donut", "chocolate", "cookie", "pie"].contains(where: { label.contains($0) }) {
            return .init(calories: 320, protein: 5, carbs: 42, fat: 15)
        }
        if ["fried", "fries", "ring", "chips"].contains(where: { label.contains($0) }) {
            return .init(calories: 280, protein: 5, carbs: 30, fat: 15)
        }
        if ["beef", "pork", "chicken", "lamb", "fish", "salmon", "steak"].contains(where: { label.contains($0) }) {
            return .init(calories: 220, protein: 23, carbs: 2, fat: 13)
        }
        return .init(calories: 180, protein: 8, carbs: 22, fat: 7)
    }
}

struct MealItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var grams: Double
    var per100g: Nutrients
    var estimateSource: String? = nil
    var nutrients: Nutrients { per100g.scaled(by: grams / 100) }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && grams.isFinite && grams > 0 && grams <= 5000 &&
        [per100g.calories, per100g.protein, per100g.carbs, per100g.fat].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1000 }
    }
    init(food: Food, grams: Double = 100) { name = food.name; self.grams = grams; per100g = food.per100g }
    init(name: String, grams: Double, per100g: Nutrients) { self.name = name; self.grams = grams; self.per100g = per100g }
}

@Model final class Meal {
    var id: UUID
    var date: Date
    var title: String
    var items: [MealItem]
    @Attribute(.externalStorage) var photo: Data?
    init(date: Date, title: String, items: [MealItem], photo: Data?) {
        id = UUID(); self.date = date; self.title = title; self.items = items; self.photo = photo
    }
    var total: Nutrients { items.reduce(Nutrients()) { $0 + $1.nutrients } }
}

enum DailySummary {
    static func meals(_ meals: [Meal], on date: Date, calendar: Calendar = .current) -> [Meal] {
        meals.filter { calendar.isDate($0.date, inSameDayAs: date) }
    }
    static func total(_ meals: [Meal]) -> Nutrients { meals.reduce(Nutrients()) { $0 + $1.total } }
}
