import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation

struct MealEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let existing: Meal?
    @State private var date: Date
    @State private var title: String
    @State private var items: [MealItem]
    @State private var photo: Data?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var suggestions: [FoodSuggestion] = []
    @State private var analysisStatus = "사진으로 음식 후보를 찾아보세요."
    @State private var busy = false
    @State private var showCamera = false
    @State private var showCustom = false
    @State private var customFoodSeedName = ""
    @State private var pendingFood: Food?
    @State private var search = ""
    @State private var confirmed = false
    @State private var error: String?
    @State private var photoTask: Task<Void, Never>?
    @State private var automaticItem: MealItem?
    private let classifier: any FoodClassifying = OnDeviceFoodClassifier()

    init(date: Date, existing: Meal? = nil) {
        self.existing = existing
        _date = State(initialValue: existing?.date ?? date)
        _title = State(initialValue: existing?.title ?? "식사")
        _items = State(initialValue: existing?.items ?? [])
        _photo = State(initialValue: existing?.photo)
    }
    private var total: Nutrients { items.reduce(Nutrients()) { $0 + $1.nutrients } }
    private var canSave: Bool { !busy && confirmed && !items.isEmpty && items.allSatisfy(\.isValid) && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        NavigationStack {
            Form {
                Section("식사") {
                    TextField("이름", text: $title)
                    DatePicker("먹은 시간", selection: $date, in: ...Date())
                }
                Section("사진 · 선택 사항") {
                    if let photo, let image = UIImage(data: photo) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 200).accessibilityLabel("분석할 식사 사진")
                    }
                    PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("사진 선택", systemImage: "photo") }.disabled(busy)
                    Button { Task { await openCamera() } } label: { Label("사진 촬영", systemImage: "camera") }.disabled(busy)
                    if photo != nil { Button("사진 제거", role: .destructive) { photo = nil; suggestions = []; selectedPhoto = nil; analysisStatus = "사진으로 음식 후보를 찾아보세요." }.disabled(busy) }
                    if busy { ProgressView("기기에서 분석 중…") }
                    Text(analysisStatus).font(.caption).foregroundStyle(.secondary)
                    if photo != nil && !busy {
                        Button("사진 다시 분석") { if let photo { photoTask = Task { await analyze(photo) } } }
                    }
                    Text("한 접시가 잘 보이도록 위에서 찍어주세요. 사진으로 접시 전체의 중량·열량을 추정하는 실험 기능이며, 국·찌개와 촬영 환경에 따라 오차가 클 수 있어요. 탄수화물·단백질·지방은 음식별 대표값으로 계산합니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("음식과 중량 확인") {
                    if items.isEmpty { Text("아래 목록에서 음식을 추가하세요.").foregroundStyle(.secondary) }
                    ForEach($items) { $item in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("음식 이름", text: $item.name)
                            if let source = item.estimateSource { Text(source).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Text("중량 (g)")
                                TextField("그램", value: $item.grams, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            }
                            if item.isValid { Text("\(item.nutrients.calories, specifier: "%.0f") kcal 추정").font(.caption).foregroundStyle(.secondary) }
                            else { Text("중량은 0보다 크고 5,000g 이하여야 합니다.").font(.caption).foregroundStyle(.red) }
                        }
                    }.onDelete { items.remove(atOffsets: $0); confirmed = false }
                }
                Section("음식 추가 · 예시 식품값") {
                    TextField("음식 검색", text: $search)
                    ForEach(FoodCatalog.foods.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.aliases.contains(where: { $0.localizedCaseInsensitiveContains(search) }) }) { food in
                        Button { pendingFood = food } label: {
                            HStack { Text(food.name); Spacer(); Image(systemName: "plus.circle") }
                        }
                    }
                    Button("직접 입력 · 포장지 영양정보") { customFoodSeedName = ""; showCustom = true }
                    Text("기본값은 검증되지 않은 MVP 예시입니다. 정확한 제품값은 포장지의 100g 기준 영양정보를 직접 입력하세요.").font(.caption).foregroundStyle(.secondary)
                }
                Section("예상 합계") {
                    Text("\(total.calories, specifier: "%.0f") kcal").font(.title2.bold())
                    MacroRow(nutrients: total)
                    Toggle("음식과 중량을 확인했어요", isOn: $confirmed)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(items.isEmpty ? "음식과 양을 선택하면 계산됩니다" : "현재 합계 · \(total.calories.formatted(.number.precision(.fractionLength(0)))) kcal 추정")
                            .font(.subheadline.bold())
                        Text("추정값은 수정할 수 있어요. 사진에 여러 음식이 있으면 전체 접시의 합계입니다.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
            .navigationTitle(existing == nil ? "식사 기록" : "식사 수정")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { photoTask?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장", action: save).disabled(!canSave) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("입력 완료") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
            }
            .onChange(of: items) { _, _ in confirmed = false }
            .onChange(of: selectedPhoto) { _, selection in
                guard let selection else { return }
                photoTask?.cancel()
                photoTask = Task {
                    busy = true
                    do {
                        guard let data = try await selection.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                        await analyze(data)
                    } catch { self.error = "사진을 열 수 없어요. 기기에 다운로드된 다른 사진을 선택해 주세요."; busy = false }
                }
            }
            .sheet(isPresented: $showCamera) { CameraView { data in photoTask = Task { await analyze(data) } }.ignoresSafeArea() }
            .sheet(item: $pendingFood) { food in FoodPortionView(food: food) { items.append($0); confirmed = false } }
            .sheet(isPresented: $showCustom) {
                CustomFoodView(initialName: customFoodSeedName) { items.append($0); confirmed = false }
            }
            .onDisappear { photoTask?.cancel() }
            .alert("안내", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("확인") { error = nil } } message: { Text(error ?? "") }
        }
    }
    @MainActor private func analyze(_ data: Data) async {
        busy = true; suggestions = []; confirmed = false
        defer { busy = false }
        do {
            let prepared = try await Task.detached { try PhotoPreparation.prepare(data) }.value
            try Task.checkCancellation()
            photo = prepared
            let result = try await classifier.classify(prepared)
            try Task.checkCancellation()
            suggestions = result.suggestions
            // Replace only an untouched automatic estimate when reanalyzing.
            // Preserve user edits and manually added items.
            if items.isEmpty || (items.count == 1 && items.first == automaticItem) {
                let label = suggestions.first?.rawLabel
                let estimate = PhotoCalorieEstimator.estimate(label: label, portion: result.portion)
                items = [estimate]
                automaticItem = estimate
                confirmed = false
                let kcal = estimate.nutrients.calories.formatted(.number.precision(.fractionLength(0)))
                let grams = estimate.grams.formatted(.number.precision(.fractionLength(0)))
                analysisStatus = result.source + " · \(estimate.name) 약 \(grams)g · \(kcal) kcal로 자동 계산했어요."
            } else {
                analysisStatus = result.source + (suggestions.isEmpty ? " · 기존 음식 항목을 유지했어요." : " · 후보를 확인하거나 기존 항목을 수정하세요.")
            }
        } catch is CancellationError { }
        catch { analysisStatus = "사진 분석에 실패했어요. 다시 사진을 선택하거나 직접 음식을 추가하세요." }
    }
    @MainActor private func openCamera() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { error = "이 기기에서는 카메라를 사용할 수 없어요. 사진 선택 또는 직접 입력을 이용하세요."; return }
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        if allowed { showCamera = true } else { error = "카메라 권한이 필요해요. 설정 앱에서 카메라 접근을 허용하거나 사진 선택을 이용하세요." }
    }
    private func save() {
        guard canSave else { return }
        if let existing { existing.date = date; existing.title = title; existing.items = items; existing.photo = photo }
        else { context.insert(Meal(date: date, title: title, items: items, photo: photo)) }
        do { try context.save(); dismiss() }
        catch { context.rollback(); self.error = "식사를 저장하지 못했어요. 입력 내용을 확인하고 다시 시도해 주세요." }
    }
}

struct CustomFoodView: View {
    let onAdd: (MealItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var item = MealItem(name: "", grams: 100, per100g: Nutrients())
    init(initialName: String = "", onAdd: @escaping (MealItem) -> Void) {
        self.onAdd = onAdd
        _item = State(initialValue: MealItem(name: initialName, grams: 100, per100g: Nutrients()))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("음식 이름", text: $item.name); field("먹은 중량 (g)", $item.grams) }
                Section("100g 기준 · 포장지에서 확인") {
                    field("열량 (kcal)", $item.per100g.calories)
                    field("탄수화물 (g)", $item.per100g.carbs)
                    field("단백질 (g)", $item.per100g.protein)
                    field("지방 (g)", $item.per100g.fat)
                }
                Text("1회 제공량 기준 값이라면 100g 기준으로 환산하여 입력하세요.").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("직접 음식 입력")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("추가") { onAdd(item); dismiss() }.disabled(!item.isValid) }
                }
        }
    }
    private func field(_ name: String, _ binding: Binding<Double>) -> some View {
        HStack { Text(name); TextField(name, value: binding, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
    }
}


struct FoodPortionView: View {
    let food: Food
    let onAdd: (MealItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var grams: Double
    init(food: Food, onAdd: @escaping (MealItem) -> Void) {
        self.food = food; self.onAdd = onAdd
        _grams = State(initialValue: food.suggestedGrams)
    }
    private var item: MealItem { MealItem(food: food, grams: grams) }
    var body: some View {
        NavigationStack {
            Form {
                Section("먹은 양 확인") {
                    HStack {
                        Text("중량 (g)")
                        TextField("그램", value: $grams, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    if FoodCatalog.soupIDs.contains(food.id) {
                        HStack {
                            Button("150g") { grams = 150 }.buttonStyle(.bordered)
                            Button("300g") { grams = 300 }.buttonStyle(.bordered)
                            Button("450g") { grams = 450 }.buttonStyle(.bordered)
                        }
                        Text("국물과 건더기를 합한 대표 1회량입니다. 먹은 양에 맞게 수정하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("선택한 양의 예상 영양") {
                    if item.isValid {
                        Text("\(item.nutrients.calories, specifier: "%.0f") kcal").font(.largeTitle.bold())
                        MacroRow(nutrients: item.nutrients)
                    } else { Text("0보다 크고 5,000g 이하인 중량을 입력하세요.").foregroundStyle(.red) }
                    Text("기본 영양값은 MVP 예시입니다. 조리법·재료에 따라 달라지며 검증된 분석 결과가 아닙니다.").font(.caption).foregroundStyle(.secondary)
                }
                Button("이 음식과 양으로 추가") { onAdd(item); dismiss() }.disabled(!item.isValid)
            }.navigationTitle(food.name)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
    }
}
