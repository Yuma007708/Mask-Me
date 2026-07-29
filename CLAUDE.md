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

## コンテキスト節約（この案件固有）

- **全読みしない**（生成物・ビルド出力・ベンダー。すべて `.gitignore` 済み）:
  `DerivedData/`（1.4G）, `build/`（1.1G）, `.build/`（292M）, `Pods/`（281M・MediaPipe/OpenCV の本体）。
  `MaskMe.xcodeproj/project.pbxproj` は XcodeGen 生成物なので開いて読まない — ビルド設定は `project.yml` を見る
  （例外は Pods 統合の生死確認で `grep -c "Pods-MaskMe"` を打つときだけ）。
- **仕様の在り処**（まずここを見れば足りる。広範に探索しない）:
  - コアロジック（描画・追従・検出率・タイムライン）→ `Sources/MosaicCore/`
  - アプリ本体 → `MaskMe/`。司令塔は `MaskMe/Model/MosaicEditorModel`
  - モザイク描画の実体 → `Sources/MosaicCore/Shaders/MosaicShader.metal`
  - ターゲット構成・ビルド設定 → `project.yml`（`.xcodeproj` ではなく）

## 開発の進め方

**PDCA を 1 サイクルとし、各フェーズを別のサブエージェントが担当する。**
専用のエージェント定義ファイルは置かない。`general-purpose` / `Plan` に `model` を指定し、
**役割は指示文で与える**。

1. **P（設計）** — 何を・どの順で・どう検証するかを決めきる。未決を残さない。
   各ステップに**完了判定**（どのテストが通れば完了か）を必ず付ける
2. **D（実装）** — 設計どおり実装し、テストを付ける。設計と食い違ったら**実装を止めて報告**する
3. **C（検証）** — **観点ごとに並列で 4 本走らせる**（1 本では出ない欠陥が出る）:
   設計との一致 / **不変条件と契約** / 敵対的テスト（壊しにかかる）/ **実地検証（設計書を読ませない）**
4. **A（反映）** — 確認できた欠陥を直す。指摘は 1 件ずつ妥当性を検証してから直す

### フェーズごとのモデル

| フェーズ | 担当 | モデル | 根拠 |
|---|---|---|---|
| 親（オーケストレータ） | 自分 | **Opus 固定** | 報告を裁定し、重い指摘を自分で再現する役。ここを下げると検証が形だけになる |
| **P**（設計） | Plan / general-purpose | **Opus** | 座標系・時刻写像・キャッシュ整合という「間違えると無言で壊れる」層の設計判断が要る |
| **D**（実装） | general-purpose | **Sonnet** | 完了判定が `swift test` / `xcodebuild test` の件数と `swiftlint --strict` という機械的な形で与えられ、解釈の余地が小さい |
| **C**（検証） | general-purpose ×4 | **不変条件と契約だけ Opus / 他の 3 観点は Sonnet** | 重い欠陥は「写像の適用順序」「キャッシュの取り違え」から出る（実績: 丸めが写像の前で rate≠1 のときバケットがずれる / `detectionCache` と `liveFlowCache` の混入）。設計との一致・敵対的テスト・実地検証は「読む」「壊す」「触る」なので下位で成果が出る |
| **A**（反映） | general-purpose | **Sonnet**（裁定が要るなら Opus） | 原因と直し方が確定した後の作業 |
| 探索・場所探し・件数の確認 | Explore | **Haiku / Sonnet** | 結論だけ持ち帰る用途。本文をダンプさせない |

- **2026-07-28 ユーザー決定でこの表にした。** 質が落ちたら 1 段ずつ戻す。
  判定は **C の指摘件数と、実素材の検出率・誤検出率の数字**で見る。
  **憶測で「Sonnet で十分」とも「Opus が必要」とも決めない** — 数字で見る。
- **親は Opus 固定を崩さない。** 下位モデルで回す構成では、報告を裁定し重い指摘を
  自分で再現する役が唯一の安全弁になる。
- サブエージェントに `model` を指定しなければ**親のモデルを継承**する（= Opus）。
  **下げるつもりで指定を忘れると黙って Opus で走る。**
- **`Agent` ツールに reasoning effort の指定は無い**（`model` / `subagent_type` /
  `isolation` だけ）。実質の調整は**指示の絞り込み**で行う（読ませる範囲を限定し、結論だけ報告させる）。

### C を並列で走らせるときの注意

**壊して確かめる観点（敵対的テスト）と、読み取り専用の観点（実地検証）を
同じ作業ツリーで同時に走らせてはいけない。** 一時的に壊れた状態を、別の観点が
本物の欠陥として報告する。

- 対策 1: 壊す観点は **`isolation: "worktree"`** で隔離する
- 対策 2: 隔離しないなら**順番に走らせる**（壊す観点 → 戻す → 読む観点）
- 対策 3: どの観点にも「**観測した時刻**と `git status --short` を報告に含める」ことを課す
- **親は「壊れている」報告を受けたら、必ず現在のディスクで再確認する**

この案件に固有の並列時の落とし穴:

- **`xcodegen generate` を絶対に走らせない**（後述。顔検出が無言でゼロになる）。
  サブエージェントへの指示に毎回明記する
- **`DerivedData/` を削除させない**（opencv-spm の xcframework 再展開が壊れる前科あり）
- **テスト件数を報告させる。** 普段の半分程度なら「テストが減った」ではなく
  **MediaPipe が外れたサイン**。件数そのものを数字で出させる
- Simulator を使う検証を複数同時に走らせない（実機・Simulator の占有で無言で失敗する）

### C の進め方

- **C は厳しく。合格を出すことが仕事ではなく、落とすべきものを落とすのが仕事。**
- **サブエージェントの報告を鵜呑みにしない。** 重い指摘は親が自分で再現してから採用する。
  観点を並列にすると必ず食い違いが出るので、そこは親が裁定する
- **テストのない修正は未修正とみなす。** 直したものには回帰テストを付ける
- **落ちないテストは無いのと同じ。** 守っているコードを 1 行壊して実際に落ちるか確かめる
- **検出の退行は誤モザイクより重い**（プライバシーアプリ）。
  誤検出を下げる修正は、必ず実顔・横顔の検出率を並べて計測してから採用する

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
