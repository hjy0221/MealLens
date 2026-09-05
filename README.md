# 한 끼 · MealLens

Native SwiftUI MVP for iOS 17+, with Korean UI. No external dependencies, accounts, API keys, external AI calls, or analytics. Open **MealLens.xcodeproj**, choose the **MealLens** scheme and an iPhone simulator, then Run. For a physical device, select your development team and a unique bundle identifier; enable HealthKit on the corresponding App ID.

## Implemented flow

1. Choose a day on the dashboard and add a meal.
2. Capture a photo, select one using the system Photos picker, or enter food manually.
3. The photo is downsampled to 1,600 pixels, oriented, and re-encoded without original EXIF/location metadata. Vision classification runs off the main actor.
4. Explicit local food-label matches become suggestions. Broad soup/stew labels offer a group of user-selectable recipes, without identifying a specific soup. Tap a candidate to add it. No candidates are automatically saved, and unknown labels yield a manual-entry prompt.
5. Add multiple foods, edit names and weights in grams, or enter your own per-100g nutrition values. Swipe an item to remove it. Default 100g is an editable placeholder, never a measured portion.
6. Confirm the foods and portions, then save. SwiftData persists the meal, nutrition snapshot, and optional photo. Open a saved meal to edit; swipe a meal on the dashboard to delete it.
7. Optionally connect HealthKit to view steps, active energy, and the latest weight at or before the selected day. Weight includes its measurement date. Missing data is shown as “—”.

## Architecture

| Component | Responsibility |
|---|---|
| `MealLensApp` | Local-only SwiftData container; recoverable storage failure screen |
| `DashboardView` / `MealDetailView` | Date selection, daily nutrition totals, meal list/detail/edit/delete, HealthKit display |
| `MealEditorView` / `CustomFoodView` | Draft state separate from persistence, photo processing, confirmation, validation, manual nutrition |
| `CameraView` | System camera capture and cancellation |
| `FoodClassifying` | Sendable asynchronous classifier boundary, suitable for test doubles |
| `OnDeviceFoodClassifier` | Actor-isolated Vision/Core ML inference, label filtering, fallback |
| `PhotoPreparation` | ImageIO downsampling/orientation/metadata stripping |
| `FoodCatalog` | Small offline seed catalog with explicit label aliases |
| `Nutrients`, `MealItem` | Portion scaling, validation, nutrient snapshots |
| `Meal` | SwiftData entity: UUID, date, title, Codable items, externally stored photo |
| `DailySummary` | Local-calendar day filtering and aggregation |
| `HealthService` | Read-only authorization, cumulative daily queries, latest weight, stale-response protection |

Nutrition is stored as snapshots in each meal item so future catalog edits do not silently change historical totals. There is no stored daily total to drift out of sync. Calendar-based day filtering supports daylight saving time. The MVP fetches all meals; move to date-bounded SwiftData queries before scaling to very large histories. SwiftData schema migration plans should be added before changing a released schema.

## Drop in a custom Core ML model

Apple's published model catalog does not supply a ready-to-use food-photo-to-nutrition pipeline. This MVP uses general Vision classification, which may produce no usable food labels. It cannot identify every dish, separate all foods on a plate, measure portions, or discover hidden ingredients.

1. Train/license an **image classifier** with image input, class-label output, and probability output compatible with `VNClassificationObservation` (for example using Create ML).
2. Add `FoodClassifier.mlmodel` or `FoodClassifier.mlpackage` to the Xcode app target. Ensure target membership is enabled so Xcode compiles it into bundled `FoodClassifier.mlmodelc`. No source-generation class is required.
3. Add each model label as an exact alias in `FoodCatalog`; current normalization lowercases labels and replaces underscores with spaces. Do not use fuzzy substring mapping for nutrition.
4. `OnDeviceFoodClassifier` automatically chooses the bundled model. Current preprocessing is `.centerCrop`; adjust this to match training preprocessing and verify orientation/crop handling on device.
5. Model load/inference failure falls back to Vision with a visible message. Confidence threshold 0.1 and top-five suggestions are provisional retrieval heuristics, not calibrated probabilities or accuracy claims.
6. Evaluate cuisine coverage, non-food rejection, top-k recall, mixed plates, lighting, latency, memory, and battery before shipping. A detector/segmenter requires a different output adapter; it is not directly interchangeable with this classifier.

Nutrition lookup remains independent of image classification and requires user-confirmed grams even with a custom model.

## Privacy and limitations

- Camera permission is requested only when taking a photo. PhotosPicker grants access to selected images without broad library permission. A photo stored only in iCloud may need an OS-managed download; inference and local recording require no network.
- HealthKit requests read access only to steps, active energy, and body mass. It never writes health records. Authorization completion does not prove read permission: Apple intentionally does not distinguish denied reads from absent records. Connection is session-scoped; reconnect after relaunch.
- HealthKit data remains in HealthKit and view state, not copied into the meal database. Refresh occurs on selected-day changes and app activation after connection; there is no background delivery.
- No CloudKit synchronization is configured. Meal photos remain in the app sandbox; ordinary device backups may include app data. Delete a meal to remove its associated record/photo. No full-data export or bulk-delete screen is included yet.
- **The fourteen seed foods use illustrative, unvalidated values. They are clearly labeled in the UI and must be replaced with a sourced, licensed, versioned dataset before public release.** Manual input allows packaging-specific values. Preparation methods, oils, sauces, edible portions, and serving units need fuller coverage.
- Calories/macros are estimates for personal logging, not medical nutrition analysis. The app does not prescribe calorie targets, diagnose conditions, calculate a health score, or subtract activity energy from food intake.

## Build and tests

```sh
xcodebuild -project MealLens.xcodeproj -scheme MealLens \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build

xcodebuild -project MealLens.xcodeproj -scheme MealLens \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.5' \
  CODE_SIGNING_ALLOWED=NO test
```

See `VALIDATION.md` for executed checks and remaining physical-device checks.

## Apple references

- [Vision image classification](https://developer.apple.com/documentation/vision/vnclassifyimagerequest)
- [Core ML model catalog](https://developer.apple.com/machine-learning/models/)
- [HealthKit authorization](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- [PhotosPicker](https://developer.apple.com/documentation/photosui/photospicker)
- [SwiftData](https://developer.apple.com/documentation/swiftdata)

## Soup recognition fix

The original ten-item catalog discarded Vision's `soup` label. `SuggestionResolver` now preserves soup/stew as a recipe-choice group. It never maps generic soup directly to one nutrition value. Four illustrative Korean soup/stew entries can be selected, followed by a gram-weight screen with a live calorie/macro preview. The 300g default is explicitly a placeholder, not a photo measurement. Manual soup selection and image retry are available even when inference finds no candidates. A persistent footer explains when food/portion input is still needed instead of leaving an unexplained zero total.

No trained Core ML food model was added by this fix. The bundled-model integration point remains available. The inspected Food-101 label list includes miso soup, French onion soup, and hot-and-sour soup, but lacks miyeok-guk and doenjang-guk; adopting that classifier alone would not add those Korean classes.

Sources: [Core ML overview](https://developer.apple.com/documentation/coreml), [Food-101 classifier labels](https://huggingface.co/nateraw/food/blob/main/config.json).
