# Nutrition5k 출처 표시

음식 분류 모델 `FoodIdentity.mlmodel`은 AI Hub의 한국 음식 이미지 150종(NIA 사업 결과물)과 ETH Zürich의 Food-101 101종으로 학습한 실험 모델입니다. 원본 사진은 앱이나 저장소에 포함하지 않습니다. 데이터 원본의 이용 조건을 보존하며 연구 평가 수치가 상용 서비스의 정확도를 보증하지 않습니다.

- AI Hub: https://www.aihub.or.kr/aihubdata/data/view.do?dataSetSn=79
- Food-101: https://data.vision.ee.ethz.ch/cvl/datasets_extra/food-101/

사진 중량·열량 실험 모델 `PhotoGrams.mlmodel`, `PhotoCalories.mlmodel`은 Google Research의 **Nutrition5k** 데이터를 사용해 MealLens에서 새로 학습했습니다.

- 원본: https://github.com/google-research-datasets/Nutrition5k
- 라이선스: Creative Commons Attribution 4.0 International (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/
- 연구: Quin Thames, Arjun Karpur, Wade Norris, Fangting Xia, Liviu Panait, Tobias Weyand, Jack Sim. “Nutrition5k: Towards Automatic Nutritional Understanding of Generic Food.” CVPR 2021, pp. 8903–8911.
- 변경: RGB 사진의 Vision revision 2 특징 추출, 유효 실측값 필터링, 촬영일별 검증 분할, 중량·열량의 로그값을 예측하는 Create ML 회귀기 학습. 원본 사진을 앱에 포함하지 않습니다.

원저자나 Google이 이 앱 또는 모델의 정확도를 보증하거나 추천한다는 뜻은 아닙니다.
