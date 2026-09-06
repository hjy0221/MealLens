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

이번 Mac 실행은 revision 2에서 `CVPixelBufferPool`, revision 1에서 `IOSurface` 오류로 멈췄습니다. RGB 8비트 검사와 한글 경로 제거로 해결되지 않았으므로 특정 경로나 메모리를 확정 원인으로 간주하지 않습니다. 실패한 분류 모델을 앱에 덮어쓰지 않습니다. 한식 원본에는 촬영 세션 정보가 없어 비슷한 연속 사진의 누출 가능성은 별도로 남아 있습니다.

일반 출처 병합·촬영 그룹 분할은 기존 `merge_global_sources.py`, `prepare_dataset.py`를 사용합니다. 도구 검사:

```sh
python3 -m unittest discover -s ModelTraining -p 'test_*.py'
```

모든 원본·중간 데이터·전체 평가 결과는 git에서 제외되는 `work/`에 보관합니다. 음식 인식 성능, 중량 오차, 열량 오차는 서로 다른 지표입니다.
