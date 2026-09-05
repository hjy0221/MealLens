import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Query(sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @State private var day = Date()
    @State private var showEditor = false
    @State private var health = HealthService()
    @State private var error: String?
    private var todaysMeals: [Meal] { DailySummary.meals(meals, on: day) }
    private var total: Nutrients { DailySummary.total(todaysMeals) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("기록 날짜", selection: $day, in: ...Date(), displayedComponents: .date)
                    VStack(alignment: .leading, spacing: 12) {
                        Label("하루의 식사를 한눈에", systemImage: "leaf.fill").foregroundStyle(.teal)
                        HStack(alignment: .firstTextBaseline) {
                            Text(total.calories, format: .number.precision(.fractionLength(0))).font(.system(.largeTitle, design: .rounded, weight: .bold))
                            Text("kcal 섭취 추정").foregroundStyle(.secondary)
                        }
                        MacroRow(nutrients: total)
                    }.padding(.vertical, 10)
                }
                Section {
                    Button { showEditor = true } label: { Label("식사 기록하기", systemImage: "camera.fill").font(.headline).padding(.vertical, 8) }
                    if todaysMeals.isEmpty {
                        ContentUnavailableView("첫 식사를 기록해 보세요", systemImage: "fork.knife", description: Text("사진으로 후보를 찾거나 직접 음식을 추가하세요."))
                    }
                    ForEach(todaysMeals) { meal in
                        NavigationLink { MealDetailView(meal: meal) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "fork.knife.circle.fill").font(.title).foregroundStyle(.teal)
                                VStack(alignment: .leading) {
                                    Text(meal.title).font(.headline)
                                    Text(meal.date, style: .time).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(meal.total.calories, specifier: "%.0f") kcal").foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }.onDelete(perform: delete)
                } header: { Text("식사 · \(todaysMeals.count)건") }
                Section("건강 앱") {
                    LabeledContent("걸음 수", value: health.steps.map { String(format: "%.0f 걸음", $0) } ?? "—")
                    LabeledContent("활동 에너지", value: health.activeEnergy.map { String(format: "%.0f kcal", $0) } ?? "—")
                    LabeledContent("최근 체중", value: health.weight.map { String(format: "%.1f kg", $0) } ?? "—")
                    if let date = health.weightDate { Text("체중 측정: \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                    Text(health.status).font(.caption).foregroundStyle(.secondary)
                    Button(health.connected ? "건강 데이터 새로고침" : "건강 앱 연결") {
                        Task { if health.connected { await health.refresh(on: day) } else { await health.connect(on: day) } }
                    }.disabled(health.loading)
                    if health.loading { ProgressView() }
                }
                Section {
                    Text("사진은 기기 내에서 분석하고 식사 기록은 이 기기에 저장해요. 음식 종류·조리법·중량에 따라 실제 영양값은 달라집니다. 기본 식품값은 MVP 예시이며 의료 또는 식이 처방용이 아닙니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("활동 에너지는 하루 총 소모량이 아니며, 섭취량에서 차감하지 않습니다.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("오늘의 한 끼")
            .sheet(isPresented: $showEditor) { MealEditorView(date: day) }
            .task(id: day) { await health.refresh(on: day) }
            .onChange(of: phase) { _, value in
                if value == .active { Task { await health.refresh(on: day) } }
            }
            .alert("저장 오류", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("확인") { error = nil } } message: { Text(error ?? "") }
        }
    }
    private func delete(_ offsets: IndexSet) {
        let selected = offsets.map { todaysMeals[$0] }
        for meal in selected { context.delete(meal) }
        do { try context.save() } catch { context.rollback(); self.error = "삭제하지 못했어요. 다시 시도해 주세요." }
    }
}

struct MacroRow: View {
    let nutrients: Nutrients
    var body: some View {
        HStack {
            metric("탄수화물", nutrients.carbs)
            Spacer()
            metric("단백질", nutrients.protein)
            Spacer()
            metric("지방", nutrients.fat)
        }
    }
    private func metric(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value, specifier: "%.1f") g").font(.subheadline.bold())
        }
    }
}

struct MealDetailView: View {
    let meal: Meal
    @State private var edit = false
    var body: some View {
        List {
            if let data = meal.photo, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).accessibilityLabel("기록한 식사 사진")
            }
            Section {
                Text(meal.date, format: .dateTime.month().day().hour().minute())
                Text("\(meal.total.calories, specifier: "%.0f") kcal · 추정").font(.title2.bold())
                MacroRow(nutrients: meal.total)
            }
            Section("확인한 음식") {
                ForEach(meal.items) { item in
                    LabeledContent(item.name, value: "\(item.grams.formatted()) g · \(Int(item.nutrients.calories)) kcal")
                }
            }
        }.navigationTitle(meal.title)
            .toolbar { Button("수정") { edit = true } }
            .sheet(isPresented: $edit) { MealEditorView(date: meal.date, existing: meal) }
    }
}
