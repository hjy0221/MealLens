# 로컬 음식 모델 학습

현재 적용 모델과 수치: [MODEL_CARD.md](MODEL_CARD.md). 데이터별 상태: [DATA_SOURCES.json](DATA_SOURCES.json). 학습과 추론에 외부 AI API를 사용하지 않습니다.

## 확보·검증한 데이터

- AI Hub 한국 음식: 기존 150종, 150,507개 이미지 파일. 상충 라벨을 가진 원본 SHA-256 387개를 이번 분할에서 제외했습니다.
- Food-101: 기존 101종, 101,000장. 이전 시험 사진 1,515장의 실제 파일 목록을 유지합니다.
- UEC FOOD 256: 추가 다운로드 파일의 ZIP CRC 검사와 압축 해제를 완료했습니다. 256종, JPEG 파일 31,395개이며 동일 사진이 여러 음식 폴더에 있습니다. 고유 파일명은 28,897개입니다. 학습에는 아직 넣지 않았습니다. 사용 전 bounding box별 라벨과 원본 사진 그룹을 유지해야 하며 비상업 연구용 조건을 따릅니다.
- Nutrition5k: 공식 버킷에서 RGB 3,490장과 영양정보·분할 목록을 추가 확보했습니다. 3,501개 객체, 약 1.46GB이며 크기와 MD5를 모두 검증하고 SHA-256 매니페스트를 남겼습니다. 공식 분할의 유효 사진 3,260장으로 중량·열량 회귀 모델 2개를 학습했습니다.

한식 400종 영양 데이터, ChineseFoodNet, VireoFood-172는 이번에 확보한 데이터가 아닙니다. 다운로드가 끝난 원본과 학습에 실제 사용한 사진을 구분합니다.

## 중량·열량 학습 재현

Mac + Xcode의 Create ML / Vision을 사용합니다. 실행 경로는 MealLens 저장소입니다. 다운로드는 네트워크를 사용하지만 학습은 Mac 내부에서 처리합니다.

```sh
python3 -u ModelTraining/download_nutrition5k.py work/global-datasets/nutrition5k
xcrun swiftc ModelTraining/TrainPhotoPortion.swift -o work/train-photo-portion
work/train-photo-portion work/global-datasets/nutrition5k work/runs/nutrition5k-rgb-v1

xcrun swiftc MealLens/PhotoPortionInference.swift MealLens/FoodClassifier.swift \
  MealLens/Nutrition.swift ModelTraining/EvaluatePhotoPortion.swift -o work/evaluate-photo-portion
work/evaluate-photo-portion work/global-datasets/nutrition5k \
  work/runs/nutrition5k-rgb-v1 work/runs/nutrition5k-rgb-v1/app-pipeline-evaluation.json
```

완료된 실행 결과를 덮어쓰지 않습니다. 재실행은 새 run 디렉터리를 지정하세요. `vision-r2-features.json`은 지정된 다운로드 데이터와 동일한 Vision revision 2 전용 캐시입니다. 데이터 또는 특징 추출 전처리를 바꾸면 별도 데이터 디렉터리에서 새로 추출하세요.

## 251종 분류 실험 재현

```sh
python3 ModelTraining/plan_expanded_training.py work/global-prepared-v3 \
  work/aihub-korea-raw-v2 work/expanded-manifest.json \
  --baseline work/runs/food101-101-lite-v1/evaluation.json
xcrun swiftc ModelTraining/NormalizeTrainingImages.swift -o work/normalize-training
work/normalize-training work/expanded-manifest.json work/expanded-normalized
python3 ModelTraining/audit_normalized_dataset.py work/expanded-normalized
python3 ModelTraining/prepare_ascii_paths.py work/expanded-normalized work/expanded-ascii
xcrun swiftc ModelTraining/TrainFoodClassifier.swift -o work/train-food
work/train-food work/expanded-ascii work/runs/new-classifier 2
```

음식당 학습 최대 150장, 검증 30장, 시험 한식 30장/Food-101 기존 15장입니다. 정규화 후 동일 사진 4장을 추가 제외해 train 37,646 / validation 7,530 / test 6,015장이 됩니다. JPEG 384px, 품질 0.9, EXIF 방향 적용을 사용합니다. ASCII 경로 매핑은 모델 metadata의 `food_label_map`으로 복원하며 앱도 이를 읽습니다.

위 MLImageClassifier 경로는 revision 2에서 `CVPixelBufferPool`, revision 1에서 `IOSurface` 오류로 멈췄습니다. 2026-09-07에는 사진별 Vision 특징 추출과 DataFrame 분류 학습으로 251종 모델을 완성했습니다. 기존 모델을 실패 시 사용할 수 있게 남겨 두고 새 모델을 우선 사용합니다. 한식 원본에는 촬영 세션 정보가 없어 비슷한 연속 사진의 누출 가능성은 별도로 남아 있습니다.

```sh
xcrun swiftc -O MealLens/FoodClassifier.swift MealLens/Nutrition.swift \
  MealLens/PhotoPortionInference.swift ModelTraining/TrainFeatureClassifier.swift -o work/train-feature-classifier
work/train-feature-classifier work/expanded-ascii work/runs/new-feature-classifier
```

완료된 모델 파일은 `FoodIdentity.mlmodel`이며 class-labels 매핑이 metadata에 포함됩니다. 전처리·분할을 바꾸는 경우 기존 특징 캐시를 재사용하지 마세요. 비교 도구 `EvaluateIdentityModels.swift`는 같은 입력에서 두 모델의 세부 라벨 정답률을 비교합니다. `CompareMealPhotos.swift`는 로컬 재현 검사 전용이며 개인 사진을 저장소에 추가하지 않습니다.

일반 출처 병합·촬영 그룹 분할은 기존 `merge_global_sources.py`, `prepare_dataset.py`를 사용합니다. 도구 검사:

```sh
python3 -m unittest discover -s ModelTraining -p 'test_*.py'
```

모든 원본·중간 데이터·전체 평가 결과는 git에서 제외되는 `work/`에 보관합니다. 음식 인식 성능, 중량 오차, 열량 오차는 서로 다른 지표입니다.

## 여러 음식 영역 탐지 실험

UEC FOOD-256의 `bb_info.txt`를 합쳐 음식 영역 한 종류(`food`)를 학습합니다. 이름 분류는 기존 FoodIdentity가 맡습니다. **서로 다른 사진도 파일 번호가 같을 수 있으므로 번호로 합치지 않습니다.** 파일 SHA-256이 같은 사진의 상자만 합친 뒤 학습/검증/시험을 80/10/10 비율로 나눕니다. 비슷하지만 파일이 다른 연속 사진까지 제거한 분할은 아닙니다.

```sh
python3 ModelTraining/prepare_detection.py \
  work/global-datasets/uecfood256/extracted/UECFOOD256 work/detection-uec-full
python3 ModelTraining/prepare_multifood_focus.py work/detection-uec-full work/detection-uec-focused
xcrun swiftc ModelTraining/TrainFoodDetector.swift -o work/train-food-detector
work/train-food-detector work/detection-uec-focused work/runs/new-food-detector 1000 --export-only
xcrun swiftc -O MealLens/FoodClassifier.swift MealLens/Nutrition.swift \
  MealLens/PhotoPortionInference.swift ModelTraining/EvaluateFoodDetector.swift \
  -o work/evaluate-food-detector
work/evaluate-food-detector work/runs/new-food-detector/FoodDetector.mlmodel \
  work/detection-uec-full/test work/runs/new-food-detector/app-evaluation.json
```

Python에는 Pillow가 필요합니다. `--limit 3000`은 해시 순서로 정한 파일럿 표본이며, 전체 실행과 같은 분할 규칙을 사용합니다. `prepare_multifood_focus.py`는 학습의 모든 다중 음식 사진과 단일 음식 1,800장을 사용하며, 검증은 모든 다중 음식 사진과 단일 음식 200장을 사용합니다. 시험 분할은 바꾸지 않습니다. Create ML의 ObjectPrint 전이 학습을 사용합니다. `--export-only` 실행 후 별도 평가를 반드시 실행합니다. 시험 평가는 Core ML 모델을 실제 Vision 경로로 불러와 신뢰도 0.4, IoU 0.5에서 음식 영역 정밀도·재현율을 계산하고, 여러 음식 사진의 결과도 별도로 기록합니다. Vision saliency를 동일 사진에서 비교하지만, saliency는 음식 전용 탐지가 아닙니다.

앱의 `OnDeviceFoodClassifier(detectorURL:)`에 컴파일된 모델을 전달해 로컬 통합 검사가 가능합니다. 배포가 승인된 모델을 Xcode 타깃 리소스에 `FoodDetector.mlmodel`로 추가하면 기본 초기화에서도 사용합니다. 탐지 모델이 없거나 실패하면 기존 사진 전체 분석을 유지합니다. **UEC 데이터는 비상업적 연구용이므로 이번 연구 모델은 `work/`에만 저장하며 공개 앱 리소스에 포함하지 않습니다.** [원본 조건](https://foodcam.mobi/dataset256.html)

2026-09-08의 정리된 v4 연구 실행은 시험 3,024장에서 음식 영역 재현율 94.1%, 정밀도 84.6%를 기록했습니다. 여러 음식 사진 125장에서는 재현율 77.0%, 정밀도 77.2%, 모든 표시 음식을 찾은 사진 72장을 기록했습니다. 동일 시험에서 Vision objectness saliency는 각각 19.3%, 37.3%, 10장이었습니다. IoU 0.5, 탐지 신뢰도 0.4 기준입니다. 이 평가는 UEC 사진의 **음식 위치만** 측정하며 음식 이름·중량·열량 정확도를 뜻하지 않습니다. 로컬 Xcode 빌드는 git에서 제외된 `MealLens/FoodDetector.mlmodel`을 사용할 수 있습니다.

영역별 중량은 기존 접시 전체 중량 예측을 상자 면적 비율로 배분하는 휴리스틱입니다. 잘라낸 이미지마다 접시 중량 모델을 반복 적용하지 않습니다. 칼로리와 영양소는 각 음식의 기본 영양값과 배분 중량으로 계산합니다. 이 데이터에는 음식별 실제 중량이 없으므로 중량 모델을 재학습하거나 중량 정확도 개선을 입증한 결과가 아닙니다. 탐지 누락, 접시/국물의 면적, 겹친 음식, 음식 높이 및 밀도는 오차 요인입니다.
