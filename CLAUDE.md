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
  MediaPipe への依存はアプリターゲット側（ルートの `MaskMe/`）でのみ発生します。これにより `swift build` /
  `swift test` だけで高速に CI を回せます。
- 補助顔検出器として MediaPipe Face Detector (BlazeFace) と YuNet (Core ML) の
  2 系統があり、`DetectionSettings` の `useFaceDetector` / `useYunet` の 2 Bool で
  個別に ON/OFF できます（Apple Vision は実機での体誤検知・Simulator での 0 検出の
  ため削除済み。詳細は README.md 参照）。
- 再生中はライブ検出（`MosaicEditorModel.liveDetectionTargetWidth`=640px 縮小 +
  IMAGE モード）が `detectionCache` を先行して
  埋め、プリスキャン（フル解像度 + VIDEO モード）が後から同じ 15fps バケットキーを
  上書きします。キー整合と空結果の扱いは `MosaicEditorModel.storePreScanResult` の
  doc コメントを参照。
- ライブ検出は `MediaPipeFaceLandmarkerAdapter.liveLandmarks(in:atMediaSeconds:)` 経由で、
  エクスポートと同じテンポラル追跡（Kalman 予測 ROI 再検出 + オプティカルフロー橋渡し）
  を IMAGE モードのまま使います（横顔・急な頭部回転対策）。シークによる時系列の巻き戻りは
  メディア時刻の不連続検知＋`notifyLiveSeek` の明示リセットで処理します。フロー由来の
  結果は実検出ではないため `detectionCache` に入れず `liveFlowCache` に別置きします
  （エクスポートはキャッシュヒットで検出をスキップするため混ぜると品質汚染になる）。

## リポジトリ構成（要点）

```
Package.swift                 # MosaicCore ライブラリ（MediaPipe 非依存）
Sources/MosaicCore/           # 描画・追従・検出率ロジック本体
Tests/MosaicCoreTests/        # MosaicCore のユニットテスト
project.yml                   # XcodeGen 定義（MaskMe / MaskMeTests / OpticalFlowKit）
Podfile                       # MediaPipeTasksVision
MaskMe/                       # SwiftUI アプリ本体
MaskMeTests/                  # 実画像・実動画での顔検出精度テスト（要 MediaPipe / Simulator）
OpticalFlowKit/               # OpenCV 隔離用の動的 framework（MediaPipe 内包の OpenCV 4.13 と非干渉）
open.sh                       # xcodegen + pod install + open workspace の一括スクリプト
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
./open.sh   # xcodegen generate → pod install → open MaskMe.xcworkspace を一括
```

または個別に:

```bash
xcodegen generate
pod install
open MaskMe.xcworkspace
```

アプリターゲットの実画像・実動画テスト（CI では実行されない。ローカル/Simulator 専用）:

```bash
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

## 現在の状況

最新状況は `.claude-handoff.md` を参照してください（このセクションはすぐ古くなるため、
詳細な CI Run 番号や残作業は handoff 側にのみ記録します）。

作業を始める前に、まず `.claude-handoff.md` の最新状況（CI Run結果・残作業・アクションリスト）
を確認してから着手してください。
