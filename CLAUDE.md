# CLAUDE.md

Mask-Me リポジトリで作業する Claude Code 向けのガイドです。

## 作業開始前に必ずやること

**`.claude-handoff.md` を読んでください。** このファイルはクラウド環境／別マシンの Claude
Code に作業を引き継ぐためのスナップショットで、git tracked のためどの clone からも見えます。
直近の調査結果・CI 実行状況・残作業・次の一手の候補がすべてここにまとまっています。作業を
区切るとき（セッション終了・大きな区切り）は、このファイルを最新状況に更新してから終えてください。

## プロジェクト概要

Mask-Me は、顔ランドマークに沿ってブロック状のモザイクを貼り付ける iOS アプリです。

- 自作の Metal コンピュートシェーダーでブロック平均を計算し、`CIPixellate` 等の既製フィルタ
  には頼らずピクセルモザイクを描画します（`Sources/MosaicCore/Shaders/MosaicShader.metal`）。
- MediaPipe Face Landmarker の 478 点メッシュを使い、顔を正面（キャノニカル）形状へ三角形単位
  で warp → そこでブロックモザイクを適用 → 現在の姿勢へ貼り戻すことで、斜め・横向きでも顔の
  3D 面に沿ってモザイクが立体的に追従します（`FaceMeshMosaicRenderer` / `FaceMeshTopology`）。
  フルメッシュが取れない場合は凸包マスク + roll 追従のフォールバックになります
  (`FaceMaskBuilder` / `MosaicShader.metal` の `blockAverage`)。
- コアロジックは **MediaPipe に一切依存しない SwiftPM ライブラリ `MosaicCore`** として分離
  されています。MediaPipe は公式 SwiftPM 配布がなく CocoaPods / xcframework のみのため、
  MediaPipe への依存はアプリターゲット側（`App/`）でのみ発生します。これにより `swift build` /
  `swift test` だけで高速に CI を回せます。
- 補助顔検出器として Apple Vision（常時 ON・実機専用）、MediaPipe Face Detector
  (BlazeFace)、YuNet (Core ML) の 3 系統があり、`DetectionSettings` の
  `useVision` / `useFaceDetector` / `useYunet` の 3 Bool で個別に ON/OFF できます
  （詳細は README.md 参照）。

## リポジトリ構成（要点）

```
Package.swift                 # MosaicCore ライブラリ（MediaPipe 非依存）
Sources/MosaicCore/           # 描画・追従・検出率ロジック本体
Tests/MosaicCoreTests/        # MosaicCore のユニットテスト
App/                          # アプリターゲット（XcodeGen + CocoaPods）
  project.yml                 # XcodeGen 定義
  Podfile                     # MediaPipeTasksVision
  MaskMe/                     # SwiftUI アプリ本体
  MaskMeTests/                # 実画像・実動画での顔検出精度テスト（要 MediaPipe / Simulator）
.github/workflows/ci.yml      # コア build/test/lint + アプリ build（Simulator, MediaPipe無し）
.github/workflows/dvalid.yml  # 実動画5本 × backend(off/faceDetector/yunet) の検出精度CI
.claude-handoff.md            # 作業引き継ぎドキュメント（cloud/別マシン向け）
```

## 開発規約・ビルド方法

- コア層（`MosaicCore`）はローカル macOS ツールチェーンだけで完結させ、MediaPipe 型を持ち込ま
  ないこと。アプリ側の `MediaPipeFaceLandmarkerAdapter` が `FaceLandmarkerResult` を
  `FaceLandmarkSet` に変換してから `MosaicCore` に渡す設計を崩さない。
- `MediaPipeFaceLandmarkerAdapter.swift` など MediaPipe 型を使うファイルは
  `#if canImport(MediaPipeTasksVision)` でガードし、pod 未導入環境（CI 含む）でもアプリが
  コンパイルできる状態を維持する。

コア層のビルド・テスト・lint:

```bash
swift build
swift test
swiftlint lint --strict
```

アプリターゲットのビルド:

```bash
cd App
xcodegen generate
pod install
open MaskMe.xcworkspace
```

アプリターゲットの実画像・実動画テスト（CI では実行されない。ローカル/Simulator 専用）:

```bash
cd App
xcodegen generate
pod install
xcodebuild test \
  -workspace MaskMe.xcworkspace \
  -scheme MaskMe \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

`.github/workflows/ci.yml` は lint / build-test（`swift build` `swift test`）/ build-app
（`xcodegen` → `xcodebuild`、CocoaPods 不使用）の3ジョブ。MediaPipe を使う実動画検証は別ワーク
フロー `.github/workflows/dvalid.yml`（5動画 × 3 backend = 最大15ジョブ並列、Google Drive から
サンプル動画を取得）で行い、これは push では自動実行されず `workflow_dispatch` で手動起動する。

## 現在のブランチ状況（fix/video-face-detection）

動画の顔検出精度チューニング作業中。直近の `dvalid.yml` CI Run（#28496967052）では
**`s1/off`・`s3/yunet`・`s5/off` の3ジョブが失敗**しており、原因調査待ちの状態です。

`.claude-handoff.md` の記録によると、`s1`/`s3` の `off`・`yunet` backend は動画長 92秒以上 +
補助検出器が MediaPipe FaceLandmarker 共有以外という組み合わせで、テストプロセスがフレーム
ループ終盤でクラッシュする構造的な flaky が確認されています（`.faceDetector` backend や短尺
動画では再現しない）。対策候補（scanner の定期再生成、フレーム間隔の見直し、テストの分割など）
は `.claude-handoff.md` の「今後の対策候補」「残作業」セクションを参照してください。

作業を始める前に、まず `.claude-handoff.md` の最新状況（CI Run結果・残作業・アクションリスト）
を確認してから着手してください。
