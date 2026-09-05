# 전 세계 음식 모델 학습 도구

현재 상태: **Food-101 전 세계 101개 클래스와 AI Hub 한식 150개 음식(약 15만 장)의 원본 확보·검증을 완료했습니다.** 클래스당 샘플을 제한한 경량 학습으로 Food-101 101개 클래스 모델을 만들고 앱에 연결했습니다. AI Hub 150개를 같은 모델에 모두 합치는 실행은 Create ML의 `CVPixelBufferPool` 오류로 중단되어 한식 원본은 다음 학습 실행을 위해 보관 중입니다. 앱은 모델이 모르는 음식도 이름 후보로 표시해 사용자가 영양정보를 확인하도록 되어 있습니다.

## 확보 대상과 사용 범위

출처별 라이선스를 보존하기 위해 데이터셋을 먼저 각각 보관한 뒤 `source__label` 형식의 별도 클래스로 병합합니다. 같은 이름의 음식이라도 출처가 다르면 자동으로 합치지 않습니다.

| 권역 | 데이터셋 | 규모 | 현재 처리 | 사용 시 주의 |
| --- | --- | ---: | --- | --- |
| 한국 | [AI Hub 한국 이미지(음식)](https://www.aihub.or.kr/aihubdata/data/view.do?currMenu=115&dataSetSn=79&topMenu=100) | 150종, 15.73GB | 로그인·신청 승인 후 확보 | NIA 출처표시, 재배포·국외반출 제한을 신청 조건에서 확인 |
| 한국·아시아·서양 | [AI Hub 음식 이미지 및 영양정보 텍스트](https://www.aihub.or.kr/aihubdata/data/view.do?aihubDataSe=realm&currMenu=&dataSetSn=74&topMenu=) | 400종 이상, 84만여 장 | 로그인·신청 승인 후 확보 | 영양정보가 있어도 원본·파생물 이용 조건을 함께 확인 |
| 세계 | [Food-101](https://huggingface.co/datasets/ethz/food101) | 101종, 약 10만 장 | 연구용 실험 데이터로만 준비 | Foodspotting 사진의 권리가 ETHZ에 있지 않으며 과학적 공정 이용 범위를 넘어서는 사용은 권리자 협의 필요 |
| 일본·국제 | [UEC FOOD 256](http://foodcam.mobi/dataset256.html) | 256종 | 출처 약관 확인 후 추가 | 공개 다운로드와 상업적 재사용 허가는 동일하지 않음 |
| 중국 | [ChineseFoodNet](https://www.kaggle.com/datasets/yihfeng/chinesefoodnet/data) | 208종, 18만여 장 | 출처·Kaggle 약관 대조 후 추가 | 학술 연구용으로 배포된 원본인지 확인하고 앱 배포 모델에는 별도 허가 필요 |
| 중국 | VireoFood-172 | 172종 | 저작자 절차 확인 후 추가 | 저작자 제공 절차와 연구·상업 범위를 확인 |

Food-101 같은 데이터는 모델 실험에는 유용하지만 권리 확인 전 상용 앱 번들에 포함하지 않습니다. 데이터 수집·학습은 기기에서 오프라인으로 처리하며, 원본 사진이나 사용자의 식사 사진을 외부 AI API로 보내지 않습니다.

## AI Hub 데이터 확보

공식 원본: https://www.aihub.or.kr/aihubdata/data/view.do?currMenu=115&dataSetSn=79&topMenu=100

확인한 파일: `kfood.zip`, 15.73 GB, 파일 키 `50036`. 다운로드와 압축 해제를 완료했고, 27개 분류 아래 150개 음식 폴더와 150,507장의 이미지를 확인했습니다. 다운로드하려면 로그인 외에 해당 데이터 신청 승인이 필요합니다. 현재 열린 신청 화면의 목적은 ‘인공지능 서비스/제품 신규 개발’입니다. 이용 조건에는 NIA 사업결과 출처 표시, 학습 목적 사용, 무단 재배포 및 국외 반출 제한 등이 있습니다. 최신 조건은 신청 화면에서 확인해야 합니다. 데이터와 모델을 상업적으로 동일하게 취급하지 않습니다. 화면은 학습 결과로 만든 제품·서비스의 영리/비영리 활용을 허용하지만 원본 데이터 제공·판매 등은 별도로 제한합니다.

원본 사진은 프로젝트의 `work/` 아래에서 보관하고 Mac에서만 처리합니다. 앱 소스 배포 ZIP에는 원본 데이터가 들어가지 않습니다. AI Hub 원본 이미지나 사진 미리보기를 외부 AI API로 전송하지 않습니다.

## 여러 출처 병합 → 준비 → 학습 → 평가

다운로드한 각 데이터셋은 먼저 별도 폴더에 압축 해제합니다. 예를 들어 각 폴더의 1단계 하위 폴더가 라벨이어야 합니다. 촬영 세션을 알 수 있다면 `라벨/촬영그룹/사진` 구조를 유지하세요. 다음 도구는 출처와 라벨을 보존하고, 동일 파일이 서로 다른 클래스로 들어가는 경우 중단합니다.

```sh
python3 ModelTraining/merge_global_sources.py /absolute/work/global-raw \
  --source aihub-korea=/absolute/work/aihub-korea/raw \
  --source food101=/absolute/work/food-101/images \
  --source chinesefoodnet=/absolute/work/chinesefoodnet/images
python3 ModelTraining/prepare_dataset.py /absolute/work/global-raw /absolute/work/global-prepared
```

`merge_global_sources.py`는 네트워크에 연결하지 않으며, 원본을 덮어쓰지 않고 SHA-256과 출처 매니페스트를 남깁니다. `prepare_dataset.py`의 클래스당 50장·3개 촬영 그룹 하한은 실험을 시작하기 위한 기준입니다. 실제 모델은 클래스별 사진 수, 지역·조명·그릇 다양성, 혼동행렬을 확인한 뒤 사용하세요.

1. 확보한 원본의 클래스와 라벨을 확인하고, 서로 구분 가능한 국 종류부터 선정합니다. 전용 모델이 모르는 음식도 평가하려면 별도 `other_food` / `non_food` 데이터가 필요합니다. 이 이름을 붙였다고 모든 미지의 음식을 거부할 수 있는 것은 아닙니다.
2. 원본을 `raw/<음식 라벨>/<같은 촬영 그룹>/<사진>`으로 정리합니다. 같은 요리·그릇을 연속 촬영한 사진은 같은 그룹에 둡니다. 라벨은 앱의 식품 ID/alias와 연결해야 합니다. `seaweed_soup`, `beef_radish_soup`, `kimchi_stew`는 현재 앱과 연결할 수 있습니다. 된장국과 된장찌개는 같은 클래스로 임의 합치지 않습니다.
3. 아래 준비 도구가 동일 파일의 중복과 상충 라벨을 검사하고, 촬영 그룹을 나누지 않은 채 학습/검증/시험용으로 약 70/15/15 분리합니다. 기본 하한은 클래스당 고유 사진 50장입니다. 이 숫자는 도구의 실험 하한일 뿐 품질 보장이 아닙니다. 지각적으로 비슷한 사진은 자동 검출하지 않으므로 원본 검토와 촬영 그룹 지정이 중요합니다.
4. Swift 도구가 이미지 디코딩과 분리 후 중복을 재확인하고, Create ML의 Image Feature Print V2를 기반으로 로컬 학습합니다. 검증 데이터는 별도로 지정하며 시험 데이터는 학습에 넣지 않습니다.
5. 시험 정확도·음식별 혼동 결과를 저장하고, 내보낸 모델을 앱과 같은 `VNCoreMLRequest`/`centerCrop` 경로로 다시 평가합니다. 보고서를 검토한 후에만 앱에 연결합니다. 높은 평균 정확도 하나만으로 실사용 성공을 주장하지 않습니다.

```sh
# MealLens 폴더에서 실행. 데이터와 실행 결과는 work 쪽 새 폴더를 지정합니다.
python3 ModelTraining/prepare_dataset.py /absolute/raw /absolute/prepared
xcrun swiftc ModelTraining/TrainFoodClassifier.swift -o /absolute/work/train-food-classifier
/absolute/work/train-food-classifier /absolute/prepared /absolute/new-run
```

실행 결과: `FoodClassifier.mlmodel`, `evaluation.json`, `confusion.csv`, `precision-recall.csv`, `manifest.json`. 이미 존재하는 데이터/학습 결과 폴더는 덮어쓰지 않습니다. 실패한 실행도 별도 폴더로 보존하며 모델 파일이 존재한다는 이유만으로 완료된 실행으로 간주하지 않습니다. `evaluation.json`의 완료 상태와 결과를 확인합니다.

## 현재 검증

- Swift 학습 도구: 이 Mac의 Xcode 26.6 SDK에서 컴파일 성공.
- 데이터 준비 테스트 3개 통과: 촬영 그룹·동일사진 누출 방지, 상충 라벨 거부, 부족한 데이터 거부.
- 데이터가 없는 상태에서 학습을 시작하면 실패 처리하는 것을 확인.
- Food-101 경량 학습(101개 클래스, train 5,050 / validation 1,515 / test 1,515)은 완료했습니다. Vision 재평가 결과 Top-1 65.8%, Top-3 83.2%이며, 모델은 검토 가능한 실험 모델로 앱에 연결했습니다. 원본 이미지 무결성 검사는 통과했습니다.
- 전체 Food-101 또는 한식 150개를 포함한 대규모 실행은 이 Mac의 Create ML에서 `CVPixelBufferPool` 오류가 발생했습니다. 샘플 수를 제한한 학습으로 메모리 문제를 우회했으며, 실제 배포 전에는 더 다양한 샘플로 재학습·검증해야 합니다.
- AI Hub 한식 원본은 `work/aihub-korea-raw-v2`에 보관하며, 목록은 `work/aihub-korean-inventory.json`으로 기록했습니다.
- 전 세계 라벨을 모르는 경우에도 모델 후보를 버리지 않고, 앱에서 음식명·중량·100g 영양정보를 직접 확인할 수 있습니다.

모델은 음식 종류를 추정하고, 앱은 음식별 대표 1회량을 적용해 사진만으로 칼로리·매크로를 계산합니다. 사진에서 실제 중량과 숨은 재료를 직접 측정하는 것은 아니므로 결과는 추정치이며, 사용자가 중량을 수정할 수 있습니다. 현재 앱의 영양값 예시를 검증된 데이터로 교체하는 작업도 별도로 필요합니다.
