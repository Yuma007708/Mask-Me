# Mask-Me

TikTok 風の「顔ピクセルモザイク」を画像・動画に適用する iOS アプリのコア実装です。
顔ランドマークの凸包でマスクを作るため、顔が斜めを向いても背景にはみ出さず顔に吸い付き、
ブロックは画像水平の粗い正方形（ハードエッジ）で覆います。粗さはスライダーで調整できます。

![参考: 顔に追従するブロックモザイク]()

## 特徴

- **自作 Metal ピクセルシェーダー** — `CIPixellate` は使用せず、コンピュートカーネルでブロック平均を計算（`Sources/MosaicCore/Shaders/MosaicShader.metal`）。
- **凸包マスク（斜め顔追従）** — MediaPipe Face Landmarker（478 点）の顔ランドマークの凸包から `CGPath` を生成（`FaceMaskBuilder`）。マスクが顔の傾きに合わせて回転するため、斜め・横向きでも顔だけを覆い背景にはみ出さない。ブロックは画像に対し水平の正方形。領域は ON/OFF で個別に切替可能。
- **統一ブロックの粗さ調整** — マスク領域は単一のブロックサイズでモザイク化し、粗さスライダー 1 本で強度を調整（ハードエッジ）。
- **追従率（0–100%）と自動復帰** — 検出信頼度を EMA で平滑化して追従率を算出。顔をロストしてもクラッシュせず `idle → searching → tracking → lost → searching → tracking` と遷移し、再検出フレームで遅延なく復帰（`TrackingEvaluator` / `TrackingStatus`）。
- **SwiftUI 連携** — `TrackingStatusStore`（`ObservableObject`）で追従状態を購読。

## アーキテクチャ

コア層は **MediaPipe 非依存の SwiftPM ライブラリ `MosaicCore`** として分離しています。
これにより `swift build` / `swift test` だけで高速・確実に CI を回せます。MediaPipe は
公式 SwiftPM 配布がなく CocoaPods / バイナリ xcframework のみのため、**アプリターゲット側**
でリンクします。

```
Mask-Me/
├─ Package.swift                       # MosaicCore ライブラリ + テスト（MediaPipe 非依存）
├─ Sources/MosaicCore/
│  ├─ FaceLandmarks.swift              # ランドマーク抽象（478点）+ 領域インデックス
│  ├─ TrackingStatus.swift            # 追従率・状態の純粋ロジック
│  ├─ DetectionRateMeter.swift        # 検出率（N件中M件検出）の集計（MediaPipe非依存）
│  ├─ FaceMaskBuilder.swift           # ランドマーク → CGPath → マスク（領域ON/OFF対応）
│  ├─ MosaicRenderer.swift            # 解析 + Metal 描画クラス
│  ├─ MetalTextureUtilities.swift     # CGImage/CVPixelBuffer ↔ MTLTexture 変換
│  └─ Shaders/MosaicShader.metal      # ピクセルシェーダー
├─ Tests/MosaicCoreTests/             # 追従ロジック・検出率・マスク生成のユニットテスト
├─ App/                               # アプリターゲット（XcodeGen + CocoaPods）
│  ├─ project.yml                     # XcodeGen 定義（MaskMe / MaskMeTests）
│  ├─ Podfile                         # MediaPipeTasksVision
│  ├─ MaskMe/
│  │  ├─ MaskMeApp.swift              # @main / NavigationStack
│  │  ├─ Views/                       # Home / Editor / RecentItems / MediaPicker / TrackingBadge
│  │  ├─ Model/                       # FaceLandmarking / MediaPipe アダプタ / 司令塔 / 最近の項目
│  │  └─ Export/                      # Photos 保存 / 動画モザイクエクスポート
│  └─ MaskMeTests/                    # 実画像での顔検出精度テスト（要 MediaPipe / Simulator）
└─ .github/workflows/ci.yml           # コア build/test/lint + アプリ build（Simulator）
```

`MosaicCore` は `FaceLandmarkSet`（正規化座標の値型）だけを入力に取り、MediaPipe の型は
一切知りません。アプリ側の `MediaPipeFaceLandmarkerAdapter` が
`FaceLandmarkerResult → FaceLandmarkSet` を変換してコアへ渡します。UI / ViewModel は
`FaceLandmarking` プロトコル越しに利用するため、pod 未導入でもアプリはコンパイルできます
（その場合は顔未検出として原画像を表示）。

## アプリのビルド・実行

```bash
cd App
xcodegen generate          # MaskMe.xcodeproj を生成
pod install                # MediaPipe を結線（MaskMe.xcworkspace 生成）
open MaskMe.xcworkspace
```

`face_landmarker.task` モデルを
[MediaPipe Models](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker)
からダウンロードし、アプリターゲットのバンドルに追加してください。

### 画面構成（王道 UI）

- **ホーム**：上部に「写真」「動画」の横並びボタン、下部に「最近の項目」（縦スクロール
  リスト、横スワイプで削除）。
- **エディタ**：モザイク結果のプレビューを上部に、下部はボトムシート風のコントロール。
  - **領域チップ**（全体 / 目元 / 口元）で、どこにモザイクを掛けるかを ON/OFF 切替。
  - **スライダー**：粗さ（モザイクの強さ＝ブロックサイズ）＋ ふち（輪郭のなめらかさ）の 2 本。
  - **追従バッジ**（追従率% ・状態）は**動画モードのみ**表示（写真は静止画のため非表示）。
  - 写真は「保存」、動画は「エクスポート」（進捗表示）。

## ビルド・テスト（コア層）

```bash
swift build
swift test
swiftlint lint --strict
```

CI（`.github/workflows/ci.yml`, macOS ランナー）は次の 3 ジョブを実行します。

- **lint**：`swiftlint --strict`（コア層）
- **build-test**：`swift build` / `swift test`（`MosaicCore`）
- **build-app**：`xcodegen generate` → `xcodebuild`（iOS Simulator 向け）。CocoaPods は
  使わず（MediaPipe コードは `canImport` で保護）、アプリターゲット・SwiftUI・Metal シェーダー
  のコンパイルを検証します。

Metal の GPU 実行は実機 / シミュレータ依存のため、ユニットテストは追従ロジック・検出率集計
・マスク生成（`CGPath`）を対象にしています。

## 実画像での顔検出精度テスト（アプリターゲット）

実際の顔写真 / 動画に対する MediaPipe の検出精度は、アプリターゲットの XCTest
（`App/MaskMeTests/`）で検証します。MediaPipe pod・モデル・実画像・Simulator が必要なため、
**CI では実行せず**ローカル / Simulator で実施します。

```bash
cd App
xcodegen generate
pod install
xcodebuild test \
  -workspace MaskMe.xcworkspace \
  -scheme MaskMe \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

- `App/MaskMeTests/Fixtures/` に実画像（`faces/` `nonfaces/`）・`sample_face.mov`・
  `face_landmarker.task` を配置します（配置方法は同フォルダの `README.md` 参照）。
  プライバシー / 著作権の都合で実画像はリポジトリに含めていません。未配置のテストは
  失敗ではなく `XCTSkip` になります。
- 検証内容：顔画像の検出率 ≥ 90%、非顔画像の誤検出率 ≤ 10%、検出ランドマークが 478 点・
  座標 `[0,1]`、動画でフレーム検出率 ≥ 80% かつ追従が `.tracking` にロックすること。
- 検出率の集計ロジック `DetectionRateMeter`（`MosaicCore`）は MediaPipe 非依存の純粋型で、
  `swift test` により CI でも回帰検証します。

## MediaPipe の解決手順（アプリターゲット）

`MosaicCore` には不要です。iOS アプリ本体に組み込む場合のみ、以下のいずれかで MediaPipe を
リンクしてください。

### CocoaPods（推奨）

```ruby
# Podfile
target 'MaskMe' do
  use_frameworks!
  pod 'MediaPipeTasksVision'
end
```

```bash
pod install
open MaskMe.xcworkspace
```

モデル `face_landmarker.task` を [MediaPipe Models](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker)
からダウンロードしてアプリバンドルに追加します。

### バイナリ xcframework

CocoaPods を使わない場合は MediaPipeTasksVision の `.xcframework` を取得し、アプリターゲットの
"Frameworks, Libraries, and Embedded Content" に追加します。

`MediaPipeFaceLandmarkerAdapter.swift` は `#if canImport(MediaPipeTasksVision)` で保護されて
いるため、pod が無い環境（CI を含む）でもパッケージはコンパイルできます。

## 使い方（概略）

```swift
import MosaicCore

let renderer = try MosaicRenderer()          // ヘッドレス環境では throw

// SwiftUI 側で追従率を表示
let store = TrackingStatusStore(renderer: renderer)
// Text("追従率 \(Int(store.status.rate))%")

// フレームごと（アプリ側で MediaPipe → FaceLandmarkSet に変換して渡す）
renderer.render(input: inputTexture, into: outputTexture, landmarks: landmarks)
```
