import SwiftUI
import SwiftData

@main struct MealLensApp: App {
    private let container: ModelContainer?

    init() {
        container = Self.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                DashboardView()
                    .modelContainer(container)
                    .tint(.teal)
            } else {
                StoreUnavailableView()
            }
        }
    }

    private static func makeContainer() -> ModelContainer? {
        try? ModelContainer(for: Meal.self, configurations: ModelConfiguration(cloudKitDatabase: .none))
    }
}

private struct StoreUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            "기록 저장소를 열 수 없어요",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text("앱을 다시 실행해 주세요. 기존 기록을 보호하기 위해 새 저장소를 만들지 않았어요.")
        )
    }
}
