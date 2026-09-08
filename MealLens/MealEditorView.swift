import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation

struct MealEditorView: View {
    private static let defaultAnalysisStatus = "사진으로 음식 후보를 찾아보세요."

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let existing: Meal?
    @State private var date: Date
    @State private var title: String
    @State private var mealType: String
    @State private var items: [MealItem]
    @State private var photo: Data?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var suggestions: [FoodSuggestion] = []
    @State private var analysisStatus = Self.defaultAnalysisStatus
    @State private var busy = false
    @State private var showCamera = false
    @State private var showCustom = false
    @State private var customFoodSeedName = ""
    @State private var pendingFood: Food?
    @State private var search = ""
    @State private var confirmed = false
    @State private var error: String?
    @State private var photoTask: Task<Void, Never>?
    @State private var automaticItems: [MealItem] = []
    @State private var detectedRegions: [ClassifiedFoodRegion] = []
    private let classifier: any FoodClassifying = OnDeviceFoodClassifier()

    init(date: Date, existing: Meal? = nil) {
        self.existing = existing
        _date = State(initialValue: existing?.date ?? date)
        _title = State(initialValue: existing?.title ?? "식사")
        _mealType = State(initialValue: existing?.mealType ?? Self.defaultMealType(for: existing?.date ?? date))
        _items = State(initialValue: (existing?.items ?? []).map { item in
            var localized = item; localized.name = FoodLabelFormatter.storedName(item.name); return localized
        })
        _photo = State(initialValue: existing?.photo)
    }

    private var total: Nutrients { items.reduce(Nutrients()) { $0 + $1.nutrients } }
    private var canSave: Bool { !busy && confirmed && !items.isEmpty && items.allSatisfy(\.isValid) && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasPhoto: Bool { photo != nil }
    private var alertIsPresented: Binding<Bool> {
        Binding(get: { error != nil }, set: { if !$0 { error = nil } })
    }
    private var filteredFoods: [Food] {
        FoodCatalog.foods.filter {
            search.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.aliases.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("식사") {
                    Picker("구분", selection: $mealType) {
                        ForEach(Self.mealTypes, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("이름", text: $title)
                    DatePicker("먹은 시간", selection: $date, in: ...Date())
                }
                Section("사진 · 선택 사항") {
                    if let photo, let image = UIImage(data: photo) {
                        DetectedMealPhoto(image: image, regions: detectedRegions)
                            .frame(maxHeight: 240)
                            .accessibilityLabel("분석할 식사 사진")
                    }
                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 6, matching: .images) { Label("사진 여러 장 선택", systemImage: "photo.on.rectangle.angled") }.disabled(busy)
                    Button { Task { await openCamera() } } label: { Label("사진 촬영", systemImage: "camera") }.disabled(busy)
                    if hasPhoto { Button("사진 제거", role: .destructive, action: resetPhotoAnalysis).disabled(busy) }
                    if busy { ProgressView("기기에서 분석 중…") }
                    Text(analysisStatus).font(.caption).foregroundStyle(.secondary)
                    if hasPhoto && !busy {
                        Button("사진 다시 분석") { startAnalysis(replaceItems: true) }
                        Text("다시 분석하면 편집 중인 음식·중량·칼로리를 새 추정값으로 바꿉니다. 저장해야 기록에 반영됩니다.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("한 접시가 잘 보이도록 위에서 찍어주세요. 사진으로 접시 전체의 중량·열량을 추정하는 실험 기능이며, 국·찌개와 촬영 환경에 따라 오차가 클 수 있어요. 탄수화물·단백질·지방은 음식별 대표값으로 계산합니다.").font(.caption).foregroundStyle(.secondary)
                    Text("샐러드·튀김류는 큰 분류로 표시합니다. 분석된 음식과 빠진 항목을 확인해 주세요.").font(.caption).foregroundStyle(.secondary)
                }
                Section("음식 이름·중량·칼로리 수정") {
                    if items.isEmpty { Text("아래 목록에서 음식을 추가하세요.").foregroundStyle(.secondary) }
                    ForEach($items) { $item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                TextField("음식 이름", text: $item.name)
                                    .font(.headline)
                            }
                            if let source = item.estimateSource { Text(source).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Text("중량 (g)")
                                TextField("그램", value: $item.grams, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            }
                            HStack {
                                Text("칼로리 (kcal)")
                                TextField("먹은 양의 칼로리", value: $item.calories, format: .number)
                                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                    .disabled(!item.grams.isFinite || item.grams <= 0)
                            }
                            if item.isValid {
                                MacroRow(nutrients: item.nutrients)
                                Text("이 음식 · \(item.nutrients.calories, specifier: "%.0f") kcal 추정")
                                    .font(.caption.bold()).foregroundStyle(.secondary)
                            }
                            else { Text("중량은 0보다 크고 5,000g 이하, 칼로리는 0 이상이어야 해요. 100g당 1,000kcal 이하로 입력해 주세요.").font(.caption).foregroundStyle(.red) }
                        }
                    }.onDelete { items.remove(atOffsets: $0); confirmed = false }
                    Text("칼로리는 먹은 양 전체의 값입니다. 중량을 바꾸면 칼로리도 같은 비율로 바뀝니다.").font(.caption).foregroundStyle(.secondary)
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
                        Text("음식별 추정값을 수정할 수 있어요. 합계는 아래 음식 항목을 더한 값입니다.").font(.caption).foregroundStyle(.secondary)
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
            .onChange(of: selectedPhoto) { _, selection in loadPhoto(selection) }
            .onChange(of: selectedPhotos) { _, selections in loadPhotos(selections) }
            .sheet(isPresented: $showCamera) { CameraView { data in photoTask = Task { await analyze(data) } }.ignoresSafeArea() }
            .sheet(item: $pendingFood) { food in FoodPortionView(food: food) { items.append($0); confirmed = false } }
            .sheet(isPresented: $showCustom) {
                CustomFoodView(initialName: customFoodSeedName) { items.append($0); confirmed = false }
            }
            .onDisappear { photoTask?.cancel() }
            .alert("안내", isPresented: alertIsPresented) { Button("확인") { error = nil } } message: { Text(error ?? "") }
        }
    }

    private func resetPhotoAnalysis() {
        photo = nil
        suggestions = []
        detectedRegions = []
        selectedPhoto = nil
        analysisStatus = Self.defaultAnalysisStatus
    }

    private func startAnalysis(replaceItems: Bool = false) {
        guard let photo else { return }
        photoTask?.cancel()
        photoTask = Task { await analyze(photo, replaceItems: replaceItems) }
    }

    private func loadPhoto(_ selection: PhotosPickerItem?) {
        guard let selection else { return }
        photoTask?.cancel()
        photoTask = Task {
            busy = true
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                await analyze(data)
            } catch {
                self.error = "사진을 열 수 없어요. 기기에 다운로드된 다른 사진을 선택해 주세요."
                busy = false
            }
        }
    }

    private func loadPhotos(_ selections: [PhotosPickerItem]) {
        guard !selections.isEmpty else { return }
        photoTask?.cancel()
        photoTask = Task {
            busy = true
            do {
                var data: [Data] = []
                for selection in selections {
                    if let value = try await selection.loadTransferable(type: Data.self) { data.append(value) }
                }
                guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                await analyzeMany(data)
            } catch {
                self.error = "사진을 열 수 없어요. 기기에 다운로드된 사진을 선택해 주세요."
                busy = false
            }
        }
    }

    @MainActor private func analyzeMany(_ data: [Data]) async {
        busy = true; suggestions = []; confirmed = false
        defer { busy = false }
        do {
            var combined: [MealItem] = []
            var firstPhoto: Data?
            for value in data {
                let prepared = try await Task.detached { try PhotoPreparation.prepare(value) }.value
                if firstPhoto == nil { firstPhoto = prepared }
                let result = try await classifier.classify(prepared)
                combined.append(contentsOf: result.estimatedItems)
            }
            guard !combined.isEmpty else { throw CocoaError(.coderInvalidValue) }
            photo = firstPhoto
            items = combined
            automaticItems = combined
            detectedRegions = []
            analysisStatus = "사진 \(data.count)장을 분석해 음식 \(combined.count)개를 모았어요. 각 음식의 이름·중량·칼로리를 확인해 주세요."
        } catch is CancellationError { }
        catch { analysisStatus = "사진 분석에 실패했어요. 다시 선택해 주세요." }
    }

    @MainActor private func analyze(_ data: Data, replaceItems: Bool = false) async {
        busy = true; suggestions = []; confirmed = false
        defer { busy = false }
        do {
            let prepared = try await Task.detached { try PhotoPreparation.prepare(data) }.value
            try Task.checkCancellation()
            photo = prepared
            let result = try await classifier.classify(prepared)
            try Task.checkCancellation()
            suggestions = result.suggestions
            detectedRegions = result.regions
            // Explicit reanalysis replaces the draft; saving commits it to the meal.
            // Otherwise preserve user edits and manually added items.
            if replaceItems || items.isEmpty || items == automaticItems {
                items = result.estimatedItems
                automaticItems = items
                confirmed = false
                let kcal = total.calories.formatted(.number.precision(.fractionLength(0)))
                let grams = items.reduce(0) { $0 + $1.grams }.formatted(.number.precision(.fractionLength(0)))
                if result.regions.count > 1 {
                    analysisStatus = "음식 \(items.count)개 영역을 분석했어요. 전체 약 \(grams)g · \(kcal) kcal 추정. 중량은 영역 크기에 따른 배분값이며, 빠진 음식이 있을 수 있어요."
                } else {
                    analysisStatus = result.source + " · 접시 전체 약 \(grams)g · \(kcal) kcal 추정. 여러 음식이 각각 구분된 결과는 아니에요."
                }
            } else {
                analysisStatus = result.source + " · 기존 음식 항목을 유지했어요. 음식 이름과 양을 수정할 수 있어요."
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
        if let existing { existing.date = date; existing.title = title; existing.mealType = mealType; existing.items = items; existing.photo = photo }
        else { context.insert(Meal(date: date, title: title, mealType: mealType, items: items, photo: photo)) }
        do { try context.save(); dismiss() }
        catch { context.rollback(); self.error = "식사를 저장하지 못했어요. 입력 내용을 확인하고 다시 시도해 주세요." }
    }

    private static let mealTypes = ["아침", "점심", "저녁", "간식"]
    private static func defaultMealType(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour { case 5..<11: return "아침"; case 11..<16: return "점심"; case 16..<22: return "저녁"; default: return "간식" }
    }
}

private struct DetectedMealPhoto: View {
    let image: UIImage
    let regions: [ClassifiedFoodRegion]

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { proxy in
                    ForEach(Array(regions.enumerated()), id: \.offset) { index, region in
                        let box = region.box
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .stroke(.cyan, lineWidth: 2)
                            Text("\(index + 1)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.cyan, in: Circle())
                                .offset(x: 3, y: 3)
                        }
                        .frame(width: box.width * proxy.size.width,
                               height: box.height * proxy.size.height)
                        .position(x: box.midX * proxy.size.width,
                                  y: (1 - box.midY) * proxy.size.height)
                    }
                }
            }
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
