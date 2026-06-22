# Mask-Me

TikTok 風の「顔ピクセルモザイク」を画像・動画に適用する iOS アプリのコア実装です。
顔輪郭に吸い付くようにモザイクが追従し、目元・口元はより細かくぼかします。

![参考: 顔に追従するブロックモザイク]()

## 特徴

- **自作 Metal ピクセルシェーダー** — `CIPixellate` は使用せず、コンピュートカーネルでブロック平均を計算（`Sources/MosaicCore/Shaders/MosaicShader.metal`）。
- **輪郭追従マスク** — MediaPipe Face Landmarker（478 点）のランドマークから `CGPath` を生成し、顔オーバル / 左右の目 / 口を塗り分けたマスクテクスチャを作成（`FaceMaskBuilder`）。
- **領域別の粗さ** — マスク値で領域を符号化し、顔は粗く・目元/口元は細かくモザイク。
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
│  ├─ FaceMaskBuilder.swift           # ランドマーク → CGPath → マスク（領域ON/OFF対応）
│  ├─ MosaicRenderer.swift            # 解析 + Metal 描画クラス
│  ├─ MetalTextureUtilities.swift     # CGImage/CVPixelBuffer ↔ MTLTexture 変換
│  └─ Shaders/MosaicShader.metal      # ピクセルシェーダー
├─ Tests/MosaicCoreTests/             # 追従ロジック・マスク生成のユニットテスト
├─ App/                               # アプリターゲット（XcodeGen + CocoaPods）
│  ├─ project.yml                     # XcodeGen 定義
│  ├─ Podfile                         # MediaPipeTasksVision
│  └─ MaskMe/
│     ├─ MaskMeApp.swift              # @main / NavigationStack
│     ├─ Views/                       # Home / Editor / RecentItems / MediaPicker / TrackingBadge
│     ├─ Model/                       # FaceLandmarking / MediaPipe アダプタ / 司令塔 / 最近の項目
│     └─ Export/                      # Photos 保存 / 動画モザイクエクスポート
└─ .github/workflows/ci.yml           # build / test / lint（コア層のみ）
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

- **ホーム**：上部に「写真編集」「動画編集」の横並びボタン、下部に「最近の項目」（縦スクロール
  リスト、横スワイプで削除）。
- **エディタ**：モザイク結果のプレビュー＋追従バッジ（追従率%・状態）、粗さスライダー（顔/目元/
  口元/ふち）と対象トグル、写真は「保存」／動画は「エクスポート」（進捗表示）。

## ビルド・テスト（コア層）

```bash
swift build
swift test
swiftlint lint --strict
```

CI（`.github/workflows/ci.yml`, macOS ランナー）でも上記を実行します。Metal の GPU 実行は
実機 / シミュレータ依存のため、ユニットテストは追従ロジックとマスク生成（`CGPath`）を対象に
しています。

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
