# オプティカルフロー・ギャップブリッジ設計（比較実験）

日付: 2026-07-04 / ブランチ: `feature/optical-flow-tracking`（main起点、PR #14マージ後）
ステータス: 承認済み（比較実験 → 勝てば採用、負ければ計測記録を残して撤退）

## 目的

検出パイプライン（MP video → enhance → bbox augment → ROI再検出 → lowConf → タイル →
顔検証パス）が全滅するフレームは、横顔・後ろ向き・強ブレ・極端な暗所など「顔らしい見た目」が
消えた区間であり、検出器の積み増しでは原理的に埋まらない。この区間を OpenCV の
オプティカルフロー（疎な Lucas-Kanade + 相似変換推定）で「画素の動き」からブリッジし、
現行の DetectionBridge 補間（hold/lerp）と精度を比較する。

ライセンス制約: 完全無料 + 商用利用可。OpenCV は Apache-2.0 で適合（精査済み）。

## 方式（案A: 疎LK + 相似変換 — 採用決定）

- 検出成功のたびに顔bbox内から特徴点を最大60個抽出（`goodFeaturesToTrack`）
- 検出全滅フレームでピラミッドLK（`calcOpticalFlowPyrLK`）で点を追跡
- 前後方向チェック: 逆向きに追跡して往復誤差 < 2px の点のみ採用
- 生存点から RANSAC（`estimateAffinePartial2D`）で相似変換（dx, dy, scale, 回転）を推定
- 最後に検出できた478点ランドマーク全体に相似変換を適用して出力

不採用案の記録: 案B 密なフロー（DIS/Farneback）は計算コスト10倍超で CI クラッシュ flaky
（累積処理量起因）を悪化させるリスクが高い。案C 既製トラッカー（KCF/CSRT）は bbox のみで
ランドマークが平行移動になり顔メッシュ貼付モザイクの品質と相性が悪い。

## コンポーネント

### 1. OpticalFlowTracker（新規、App層 ObjC++ ラッパー）

- ファイル: `App/MaskMe/Model/OpticalFlowTracker.h` / `.mm`。OpenCV 依存はこの1ファイルに
  閉じ込める（MosaicCore の MediaPipe/OpenCV 非依存規約を維持）
- API（Swiftから利用）:
  - `reset()`
  - `seed(pixelBuffer, faceBox)` — 検出成功のたびに呼び、特徴点と参照フレームを更新
  - `advance(pixelBuffer) -> FlowResult?` — 相似変換 + 品質指標。品質ゲート不合格なら nil
- 品質ゲート: 生存点 ≥ 15 かつ seed 時の 40% 以上 / 1フレームのスケール変化 0.7〜1.4 以内
- コスト対策: 輝度プレーンのみ・長辺 640px に縮小して処理（CI クラッシュ flaky 対策）

### 2. Adapter統合（`MediaPipeFaceLandmarkerAdapter`）

- 全段失敗時のみフロー発動。連続フロー上限 **30フレーム** で打ち切り（ドリフト対策、
  プローブで調整可）。実検出が復帰したら即スナップ
- フロー結果で `trackedFaces` の bbox も前進させる → 次フレームの ROI 再検出が
  フロー予測位置を走査（track延命→実顔再取得の早期化効果の強化版）。missCount はリセット
  しない（フローは顔の存在を証明しない）
- 複数顔は track ごとに独立フローインスタンス（上限3）

### 3. ランドマーク変換（MosaicCore、純粋幾何）

- `SimilarityTransform` 型と `FaceLandmarkSet` への適用関数を MosaicCore に追加
- OpenCV 非依存の純粋関数 → `swift test` でユニットテスト可能

### 4. 導入

- `App/Podfile` に公式 Pod `OpenCV` を追加（App target のみ）
- バイナリサイズ増は実験段階では許容。採用時に部分ビルド（core+imgproc+video のみ）を
  別課題として起票

## 実装での確定・変更事項（2026-07-05 追記、実装済みの正）

上記コンポーネント記述からの実装時変更。詳細な経緯は `.superpowers/sdd/progress.md` 参照。

1. **OpenCV は opencv-spm 5.0.0（SPM, Apache-2.0）を採用**（§4 の CocoaPods 案から変更）。
2. **OpenCV 依存は専用動的 framework `App/OpticalFlowKit/` に隔離**（§1 の
   `App/MaskMe/Model/` 直下案から変更）。MediaPipe の graph static lib が OpenCV 4.13 を
   force_load 内包（cv:: シンボル3,534個）しており、アプリターゲット直リンクは ABI 混線で
   クラッシュするため。**OpenCV を使うコードは必ず OpticalFlowKit ターゲット内に置くこと。**
3. **相似変換の推定は純 Swift**（MosaicCore の `SimilarityTransform.estimate`）。
   `advance` は対応点ペア（`MMFlowMatch`）を返すだけにし、OpenCV の推定APIは使わない。
   scale 0.7〜1.4 ゲートは Adapter 側で適用。
4. **フローブリッジ適格ゲート**（`isFlowBridgeEligible`、Adapter）を追加:
   面積 ≤ 0.08 **かつ** bbox 中心 midY ≤ 0.5 のトラックのみブリッジする。
   - 面積ゲート: s5_A の体誤検出（面積0.11〜0.17、真顔は≤0.06）の延命防止
   - cy ゲート: s5_B の弱ソース（enh/low/tile）低位置検出（顔サイズ・cy0.49〜0.69）の
     延命防止。s4/s1 のフロー利得への損失は実測239フレーム中1のみ
   - 不適格でも「baseline 挙動（ミス）に戻るだけ」の安全な劣化
5. **grayMat はフル解像度確保なしの直接縮小描画**（縮小サイズの Mat/CGContext に
   `kCGInterpolationMedium` で描画）。CI ランナーのメモリ圧対策。
6. 確定パラメータ: `maxFlowFrames=30` / `kMinSurvivorRatio=0.40` /
   `maxFlowBridgeArea=0.08` / `maxFlowBridgeCenterY=0.5`。
   maxFlowFrames=15 と kMinSurvivorRatio=0.55 はプローブで**効果ゼロ**を実証済み
   （誤検出領域は光学的に安定追跡できるため品質パラメータでは排除不可能）。

## 計測・比較方法（1回のCIランで自己対照）

- フロー供給フレームは `src=flow` タグ。DVALRESULT に `flowHits` / `flowRate` を新設。
  既存 `rate`（生検出率）の定義は不変
- 注意: フローが ROI の track 位置を前進させるため実検出の rate 自体も変わり得る（改善方向）。
  比較は「PR #14 確定値 vs 今回」の3指標で行う:
  1. `rate` — フローの実検出への波及効果
  2. `flowRate` — フロー込み検出率
  3. `bridgedRate` — アプリ体験（DetectionBridge 補間込み）
- 番犬メトリクス: s5 lowCy% ≤ 7.0 維持 / avgJump 悪化 +1pp 以内。フローによる誤検出延命を検知
- DVALFRAME タイムラインの src=flow でギャップ埋まり方をオフライン分析可能

### PR #14 確定 baseline（Run #28667623782、off backend）

| 動画 | rate | bridgedRate |
|---|---|---|
| s1 | 77.4% | 79.6% |
| s2 | 88.9% | 89.3% |
| s3 | 95.6% | 96.4% |
| s4 | 17.4% | 28.2% |
| s5 | 70.3% | 79.0% |

## 採用基準（勝敗ライン）

- **勝ち**: s1/s4/s5 のいずれかで bridgedRate +3pp 以上、かつ番犬クリア、かつ CI ジョブが
  timeout 90分内 → PR 化
- **負け**: 上積み +3pp 未満 or 番犬悪化 → 計測記録を handoff / Notion ナレッジに残して
  ブランチ撤退（PR クローズ）

## テスト計画

1. MosaicCore: `SimilarityTransform` 適用のユニットテスト（swift test）
2. App層: OpticalFlowTracker の合成画像テスト（平行移動した市松模様で dx/dy 一致、
   全面フラット画像で品質ゲート nil を検証）
3. DValid CI: フルラン（5動画 × 3backend × 2half）で上記3指標 + 番犬を比較

## ワークフロー

1. Podfile 追加 + pod install + ビルド確認
2. MosaicCore 幾何 + ユニットテスト → ラッパー + 合成画像テスト → Adapter 統合
3. ローカルプローブ3本（s4_off=最長ギャップ / s1_off_B / s5_off_A=番犬）でパラメータ調整
   （フロー上限・品質ゲート閾値）
4. CI フルラン → 比較表 → 採否判断
5. 区切りごとに `.claude-handoff.md` 更新、完了時に PJ 記録・Notion ナレッジ反映

## リスク

- フローが体誤検出 track を延命 → 品質ゲート + 上限30フレーム + lowCy 番犬で検知
- CI 処理時間増・クラッシュ flaky 悪化 → 縮小グレースケール処理でフレームあたり数ms に抑制、
  ジョブ時間を比較表に含めて監視
- OpenCV Pod のバイナリサイズ増 → 実験段階は許容、採用時に部分ビルド課題化
- Simulator での OpenCV 動作は CPU のみで完結するため GPU 系 flaky とは独立
