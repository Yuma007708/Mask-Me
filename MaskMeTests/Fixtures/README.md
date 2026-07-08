# テストフィクスチャ（実画像検出精度テスト）

`DetectionAccuracyTests` / `VideoDetectionTests` は、ここに置いた**実画像**に対して
MediaPipe Face Landmarker を実行し、検出率・誤検出率・ランドマーク妥当性を検証します。

プライバシー・著作権の都合で**実画像はリポジトリに含めていません**。各自で用意して
以下の構成で配置してください。ファイルが無い場合、該当テストは失敗ではなく `XCTSkip`
（スキップ）になります。

## 配置

```
App/MaskMeTests/Fixtures/
├─ face_landmarker.task     # MediaPipe モデル（アプリと共用可。テストにも必要）
├─ faces/                   # 顔が写っている画像（jpg/jpeg/png/heic）
│  ├─ face_01.jpg
│  └─ ...
├─ nonfaces/                # 顔が写っていない画像（風景・物など）
│  ├─ scene_01.jpg
│  └─ ...
└─ sample_face.mov          # 顔が映る短い動画（数秒で可）
```

## しきい値（テスト内で定義）

- `faces/`：検出率 **≥ 90%**
- `nonfaces/`：誤検出率 **≤ 10%**
- `sample_face.mov`：フレーム検出率 **≥ 80%** かつ追従が `.tracking` にロックすること

しきい値は `DetectionAccuracyTests` / `VideoDetectionTests` の定数で調整できます。

## 実行方法

```bash
cd App
xcodegen generate
pod install
xcodebuild test \
  -workspace MaskMe.xcworkspace \
  -scheme MaskMe \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

または Xcode で `MaskMe.xcworkspace` を開き **Cmd+U**。

> 注: これらのテストは MediaPipe pod・モデル・実画像・Simulator が必要なため、
> pod 無しの CI（`build-app`）では実行しません。検出率の集計ロジック
> （`DetectionRateMeter`）は MosaicCore 側で `swift test` により CI で検証されます。
