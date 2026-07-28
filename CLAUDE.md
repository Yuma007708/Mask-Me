# CLAUDE.md

TikTok 風の「顔ピクセルモザイク」を画像・動画・アプリ内カメラに適用する iOS アプリ。
MediaPipe の 478 点顔メッシュで顔を正面形状へ warp → ブロックモザイク → 貼り戻すことで、
斜め・横向きでも顔の 3D 面に吸い付く立体モザイクを自作 Metal コンピュートシェーダーで描画する。

## 技術スタック

- 言語/ランタイム: Swift（言語モード 5.9 固定、`SWIFT_VERSION: "5.9"`）/ iOS 16.0+ / Objective-C++（OpticalFlowKit のみ）
- UI: SwiftUI（`NavigationStack` / `ObservableObject`）
- 描画: Metal コンピュートシェーダー（`Sources/MosaicCore/Shaders/MosaicShader.metal`。`CIPixellate` 等は不使用）
- 顔検出: MediaPipeTasksVision 0.10.35（CocoaPods、Face Landmarker 478 点 + BlazeFace）/ YuNet（Core ML `yunet.mlmodel`）
- オプティカルフロー: OpenCV 5.0（SwiftPM binary `yeatse/opencv-spm`、**OpticalFlowKit ターゲット限定**）
- プロジェクト生成: XcodeGen（`project.yml` が唯一のソース。`.xcodeproj` は生成物）
- 依存管理: SwiftPM（コア層 `MosaicCore`）+ CocoaPods 1.16.2（MediaPipe のみ）
- Lint: SwiftLint（`.swiftlint.yml`、対象は `Sources` / `Tests` / `MaskMe`）
- CI: GitHub Actions macos-15（`ci.yml`: lint / core build-test / app build。`dvalid.yml`: 実動画検出精度、手動起動）

## 実装前の確認（context7）

- 上記スタックの外部ライブラリ/フレームワーク/SDK（MediaPipeTasksVision、OpenCV、SwiftUI /
  AVFoundation / Metal / Core ML のバージョン依存 API、XcodeGen・CocoaPods の設定仕様）を使う
  実装の前に、`context7`（MCP: `mcp__context7__*`）で最新ドキュメント・API 仕様を確認する。
  学習データが古い可能性があるため、既知のものでも裏取りする。
- 適用対象: バージョン依存の API・設定・移行・セットアップ手順。
  汎用的なプログラミング概念や自明な標準機能には使わない。

## コマンド

コア層（`MosaicCore`、MediaPipe 非依存。ローカル toolchain だけで完結）:

```bash
swift build
swift test
swiftlint lint --strict
```

アプリターゲット:

```bash
xcodegen generate          # project.yml → MaskMe.xcodeproj
pod install                # MediaPipe を結線（MaskMe.xcworkspace 生成）
open MaskMe.xcworkspace
```

実画像・実動画の検出精度テスト（要 MediaPipe pod + Fixtures + Simulator。CI では実行されない）:

```bash
xcodebuild test \
  -workspace MaskMe.xcworkspace \
  -scheme MaskMe \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

- `MaskMeTests/Fixtures/` に実画像・動画・`face_landmarker.task` を配置（未配置は `XCTSkip`）。
- 実動画 5 本 × backend の網羅検証は `.github/workflows/dvalid.yml` を `workflow_dispatch` で手動起動。

## ディレクトリ構成

```
Package.swift                 # MosaicCore ライブラリ定義（MediaPipe 非依存）
Sources/MosaicCore/           # 描画・追従・検出率・タイムラインのコアロジック
Tests/MosaicCoreTests/        # MosaicCore ユニットテスト（swift test で実行）
project.yml                   # XcodeGen 定義（MaskMe / MaskMeTests / OpticalFlowKit）
Podfile                       # MediaPipeTasksVision（post_install で force_load 二重登録を除去）
MaskMe/                       # SwiftUI アプリ本体
├─ Views/                     # Home / Editor / Camera / Settings / Timeline 等
├─ Model/                     # MediaPipe アダプタ・MosaicEditorModel（司令塔）・検出器群
├─ Camera/                    # リアルタイムモザイク撮影パイプライン
└─ Export/                    # Photos 保存 / 動画モザイクエクスポート
MaskMeTests/                  # 実画像・実動画テスト（要 MediaPipe / Simulator）
OpticalFlowKit/               # OpenCV 疎 LK フローの動的 framework（シンボル隔離）
```

## アーキテクチャ規約（崩さないこと）

- **`MosaicCore` は MediaPipe に一切依存しない。** アプリ側の `MediaPipeFaceLandmarkerAdapter` が
  `FaceLandmarkerResult → FaceLandmarkSet`（正規化座標の値型）に変換してからコアへ渡す。
- MediaPipe 型を使うファイルは `#if canImport(MediaPipeTasksVision)` でガードし、
  pod 未導入環境（CI 含む）でもコンパイル可能な状態を維持する。
- **OpenCV を使ってよいのは OpticalFlowKit ターゲットだけ**（公開 API は Foundation/UIKit 型のみ）。
  MediaPipe の static library が OpenCV 4.13 を内包しており、アプリターゲットで OpenCV 5.0 を
  リンクするとシンボル衝突で ABI が混線するため、動的 framework に隔離してある。
  同じ理由で **MaskMeTests に OpenCV package を追加しないこと**（project.yml のコメント参照）。
- カメラフレームは常にポートレート回転・非ミラーに正規化し、フロントカメラの鏡像は
  表示レイヤーのみで行う（検出・描画・保存の座標系を一致させるため）。
- オプティカルフロー由来の顔位置は実検出ではないため `detectionCache` に入れず
  `liveFlowCache` に別置きする（エクスポートはキャッシュヒットで検出をスキップするため、
  混ぜると品質汚染になる）。キー整合は `MosaicEditorModel.storePreScanResult` の doc コメント参照。
- カメラ撮影は**モザイク焼き込み済みメディアだけを保存**する設計（原本は残さない。
  レコーダー層は描画済みバッファ以外を受け取らない）。

## ⚠️ `xcodegen generate` の後は必ず `pod install`

`xcodegen generate` は `.xcodeproj` を作り直すため、CocoaPods の統合情報（base configuration・
`[CP]` ビルドフェーズ・リンカフラグ）が**丸ごと消える**。このとき MediaPipe を使うコードは
`canImport` ガードで外れるだけなので、**ビルドもテストも成功したまま顔検出だけが無言でゼロになる。**

判定方法:

```bash
grep -c "Pods-MaskMe" MaskMe.xcodeproj/project.pbxproj   # 0 なら統合が消えている
```

テスト件数を検証根拠にするときは件数そのものを確認すること。実行件数が普段の半分程度に
落ちていたら「テストが減った」のではなく **MediaPipe が外れているサイン**。
