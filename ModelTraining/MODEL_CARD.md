# MealLens FoodClassifier · 실험 모델

- **모델 파일:** `../FoodClassifier.mlmodel`
- **학습 방식:** Apple Create ML 이미지 분류기, Scene Print V2 특징 추출기, 로지스틱 회귀
- **클래스:** Food-101 101개 음식
- **학습 샘플:** 클래스당 train 최대 50장, validation 15장, test 15장
- **Vision 재평가:** held-out 1,515장 기준 Top-1 65.8%, Top-3 83.2%
- **실행:** iPhone의 Vision `VNCoreMLRequest`와 `centerCrop` 경로로 확인

이 모델은 음식 종류를 분류하고, 앱은 사진과 음식 종류를 바탕으로 먹은 양을 추정해 칼로리를 계산합니다. 사진에서 실제 중량·재료를 직접 측정하는 것은 아니며, 사용자는 결과 화면에서 필요하면 음식명과 추정 중량을 수정할 수 있습니다.

AI Hub 한식 150개 음식 원본은 확보·색인했지만, 251개 통합 학습은 현재 Mac Create ML의 `CVPixelBufferPool` 오류로 중단됐습니다. 따라서 이 모델의 평가 수치가 한식 150개를 포함한다는 뜻은 아닙니다. AI Hub 이용 조건과 원본 사진 권리를 검토한 뒤 별도 경량 모델 또는 더 큰 학습 환경에서 재학습해야 합니다.
