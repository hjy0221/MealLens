# Validation · 2026-09-05

Environment: Xcode 26.6 (17F113), Swift 6.3.3 compiler in Swift 5 language mode. Deployment target iOS 17.0.

## Passed

- Debug build for iOS Simulator (arm64 and x86_64).
- Release build for iPhoneOS / arm64 with signing disabled (compile/link verification, not a distributable signed archive).
- Normal simulator build with simulator entitlement packaging enabled.
- Six XCTest cases on iPhone 15 Pro / iOS 17.5, zero failures:
  - Known mixed-meal calorie and macro calculation at different gram weights.
  - Zero, negative, non-finite, and out-of-range portion rejection.
  - Exact alias normalization and unknown/ambiguous label rejection.
  - Local-day boundaries including a 23-hour daylight-saving day.
  - On-disk SwiftData save, fresh-container reload, nutrition snapshot and photo round trip, update, and deletion.
  - Corrupt image preprocessing and Vision inference fail safely.
- Interactive simulator check: launched the empty dashboard, opened meal entry, added 100g rice, checked the explicit confirmation toggle, saved, and verified 130 kcal / 28.2g carbs / 2.7g protein / 0.3g fat on dashboard and meal detail.
- Visually inspected native form and dashboard layout. `Previews/dashboard.png` is an actual simulator screenshot with a test meal, not a mockup or bundled demo record.
- Food-101 official archive downloaded to the local `work/` area and verified against the published SHA-256 (`d97d15e438b7f4498f96086a4f7e2fa42a32f2712e87d3295441b2b6314053a4`).
- Food-101 was expanded to 101,000 images, namespaced, conflicting duplicate labels quarantined, and prepared as 70,690 train / 15,150 validation / 15,150 test images across 101 classes.
- Python data-pipeline tests: five cases passed, including source namespacing and contradictory-label quarantine.

The unsigned test invocation emitted an expected HealthKit missing-entitlement message; it did not exercise authorization. A subsequent normal simulator build packages HealthKit in the simulated entitlements. Do not use `CODE_SIGNING_ALLOWED=NO` for HealthKit integration testing.

## Remaining device/release validation

- Physical-camera permissions, denied permission recovery, capture/cancel, and orientation.
- Real food images across cuisine and lighting; a capped 101-class Food-101 Create ML run exported `FoodClassifier.mlmodel` and Vision re-evaluation measured 65.8% Top-1 / 83.2% Top-3 on 1,515 held-out images. The model is experimental and now bundled in the app.
- Photo selection including iCloud-only images, large HEIC files, cancellation, and unavailable image data.
- HealthKit authorization denial/partial access, real activity and weight samples, calendar boundaries, refresh, and no-data states with a correctly provisioned device.
- Dropped-in custom model load, malformed/nonclassifier fallback, preprocessing compatibility, and performance.
- Full VoiceOver and accessibility text-size audit, iPad layout, and large-history performance.
- Replace illustrative food values with a verified, licensed nutrition dataset; add catalog provenance and versioning.
- Add release app icon/assets, privacy disclosures, signing/provisioning, and App Store metadata before distribution.

## Physical-device build update

- Signed Debug build succeeded for the connected 재윤의 iPhone (iPhone 17) using automatic provisioning.
- Project development team and unique bundle identifier are now configured for this local developer account.

- Added a 1024px opaque generated AppIcon, confirmed compiled icon metadata, and passed signed iPhone Debug build.

## Soup flow fix

- Verified macOS Vision supported identifiers include `soup`; discovered the previous catalog had no soup mapping.
- Nine deterministic XCTest cases passed on iOS 17.5, including generic soup recipe-choice mapping, weak-label rejection/deduplication, and portion math.
- A separate attempted iOS 17.5 simulator taxonomy query failed with Vision `Could not create inference context`; this environment therefore does not validate successful real-image inference. The final resolver tests use controlled label observations.
- Signed iPhone Debug build passed and the update installed on 재윤의 iPhone.
- Visually checked soup selection and the portion screen on the simulator: the illustrative 300g entry shows 75 kcal and switching to 150g shows 38 kcal rounded.
- The user's original soup photo was not provided; its classification result and recipe accuracy have not been verified. No trained Core ML model has been added.

## Global-data acquisition update

- Chrome + INNORIX downloaded AI Hub `kfood.zip` to the user's Downloads folder. The 16 GB archive was verified as a Zip archive, expanded locally, and indexed as 27 categories / 150 dishes / 150,507 images; the original is not copied into the project or deliverable ZIP.
- AI Hub's account page shows the Korean food request as automatic approval. The download page required the INNORIX agent and PC-only transfer; the agent installer was downloaded but not installed without the user's explicit approval.
- Food-101 is retained for local research experimentation only until rights for the source photographs are cleared for the intended app distribution.
- The full 101-class and combined 251-class runs hit Create ML's `CVPixelBufferPool` zero-size error; the capped 101-class run is the reproducible memory-stable baseline. It must be re-evaluated with cleared data rights and broader independent captures before release.
- The generated `FoodClassifier.mlmodel` is included in the signed app bundle and the updated build was installed on 재윤의 iPhone.
- Photo-only estimate flow now creates a valid meal item automatically: food label → representative serving grams → calories/macros. The item remains editable before saving.

## 사용성 점검 · 2026-09-06

- 빈 대시보드에서 `식사 기록하기`를 바로 찾을 수 있는지 iPhone 15 Pro 시뮬레이터에서 확인했습니다.
- 사진 선택·사진 제거·다시 분석·직접 음식 추가·중량 입력·확인 토글·저장 흐름을 코드와 UI 상태로 점검했습니다.
- 저장 버튼은 음식·중량 검증과 확인 토글을 모두 통과해야 활성화되어, 후보만 보고 잘못 저장하는 흐름을 막습니다.
- 모델의 내부 출처 접두사는 화면과 직접 입력란에 노출하지 않도록 정리했습니다.
- iOS 17.5 시뮬레이터 XCTest 10개가 모두 통과했습니다. SwiftData 테스트에서 시뮬레이터 SQLite 진단 로그가 출력됐지만 테스트 결과와 저장·수정·삭제 검증은 통과했습니다.
