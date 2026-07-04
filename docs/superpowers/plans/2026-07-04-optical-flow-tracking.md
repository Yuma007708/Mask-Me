# オプティカルフロー・ギャップブリッジ実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 検出パイプライン全滅フレームをOpenCVの疎LKオプティカルフローでブリッジし、DValid CIで現行補間と比較、勝てば採用する。

**Architecture:** OpenCV依存はApp層のObjC++ラッパー1ファイル（特徴点追跡のみ）に閉じ込め、相似変換の推定・適用は純SwiftのMosaicCoreコード（ユニットテスト可能）で行う。Adapterは全段失敗時のみフローを発動し `src=flow` でタグ付けするため、1回のCIランで自己対照比較ができる。

**Tech Stack:** OpenCV 4.x（core/imgproc/video、Apache-2.0）、SwiftPM binary（opencv-spm）またはCocoaPods、ObjC++ブリッジ、XCTest、DValid CI。

**スペック:** `docs/superpowers/specs/2026-07-04-optical-flow-tracking-design.md`

## スペックからの実装詳細変更（要スペック追記、Task 7で反映）

1. **相似変換推定はOpenCVの`estimateAffinePartial2D`ではなくMosaicCoreの純Swift実装**（Umeyama法+外れ値除去の再フィット）。理由: swift testでユニットテスト可能になり、OpenCVの使用APIが`goodFeaturesToTrack`+`calcOpticalFlowPyrLK`の2つに減り、必要モジュールがcore/imgproc/videoのみになる。
2. **導入経路は公式CocoaPods `OpenCV` を使わない**。同Podは4.3.0（2020年）で更新停止しておりarm64シミュレータスライスがない疑いが濃厚（Apple Silicon のローカル/CIで詰む）。第一候補は opencv-spm（公式ソースビルドのSwiftPM binary、Apache-2.0）、検証不合格なら `build_xcframework.py` で最小モジュール自前ビルド。

## Global Constraints

- ライセンス: 完全無料+商用利用可のみ（OpenCV本体はApache-2.0。配布物採用前にLICENSEファイルを実際に確認する）
- MosaicCore（`Sources/`）にOpenCV/MediaPipeの依存を入れない。OpenCVを触るのは `App/MaskMe/Model/OpticalFlowTracker.{h,mm}` のみ
- 座標系: FaceLandmark/boundingBoxは正規化[0,1]・原点左上。フロー・相似変換の計算は**フルフレームのピクセル空間**（`cgImage.width/height`）で行い、出入口で変換する
- 番犬: s5 lowCy% ≤ 7.0 維持 / avgJump悪化 +1pp以内 / CIジョブ90分以内
- コミットは日本語メッセージ、区切りごとに `.claude-handoff.md` 更新（リポジトリ規約）
- テスト・ドキュメントのない実装禁止（グローバル規定）
- サンプル動画は成人向け内容を含む。フレーム目視は行わず数値（DVALRESULT/DVALFRAME）で判断する

---

### Task 1: MosaicCore — SimilarityTransform（推定+適用、TDD）

**Files:**
- Create: `Sources/MosaicCore/SimilarityTransform.swift`
- Test: `Tests/MosaicCoreTests/SimilarityTransformTests.swift`

**Interfaces:**
- Produces:
  - `public struct SimilarityTransform { public let scale: CGFloat; public let rotation: CGFloat; public let tx: CGFloat; public let ty: CGFloat }`（ピクセル空間: `p' = scale·R(rotation)·p + (tx,ty)`）
  - `public static func estimate(from: [CGPoint], to: [CGPoint]) -> SimilarityTransform?`（対応点ペアから推定。6ペア未満/インライア比0.5未満はnil）
  - `public func apply(to set: FaceLandmarkSet, imageSize: CGSize) -> FaceLandmarkSet`
  - `public func apply(toNormalizedRect rect: CGRect, imageSize: CGSize) -> CGRect`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MosaicCoreTests/SimilarityTransformTests.swift`:

```swift
import XCTest
@testable import MosaicCore

final class SimilarityTransformTests: XCTestCase {

    // MARK: - estimate

    func test_estimate_pureTranslation() throws {
        let from = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10),
                    CGPoint(x: 50, y: 60), CGPoint(x: 10, y: 60),
                    CGPoint(x: 30, y: 35), CGPoint(x: 20, y: 50)]
        let to = from.map { CGPoint(x: $0.x + 12, y: $0.y + 7) }
        let t = try XCTUnwrap(SimilarityTransform.estimate(from: from, to: to))
        XCTAssertEqual(t.tx, 12, accuracy: 0.01)
        XCTAssertEqual(t.ty, 7, accuracy: 0.01)
        XCTAssertEqual(t.scale, 1.0, accuracy: 0.001)
        XCTAssertEqual(t.rotation, 0.0, accuracy: 0.001)
    }

    func test_estimate_scaleAndRotation() throws {
        // 原点中心に 1.2 倍 + 30度回転 + 平行移動(5, -3)
        let s: CGFloat = 1.2, r: CGFloat = .pi / 6
        let from = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0),
                    CGPoint(x: 40, y: 40), CGPoint(x: 0, y: 40),
                    CGPoint(x: 20, y: 10), CGPoint(x: 10, y: 30)]
        let to = from.map { p in
            CGPoint(x: s * (cos(r) * p.x - sin(r) * p.y) + 5,
                    y: s * (sin(r) * p.x + cos(r) * p.y) - 3)
        }
        let t = try XCTUnwrap(SimilarityTransform.estimate(from: from, to: to))
        XCTAssertEqual(t.scale, 1.2, accuracy: 0.001)
        XCTAssertEqual(t.rotation, .pi / 6, accuracy: 0.001)
        XCTAssertEqual(t.tx, 5, accuracy: 0.01)
        XCTAssertEqual(t.ty, -3, accuracy: 0.01)
    }

    func test_estimate_rejectsTooFewPairs() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        XCTAssertNil(SimilarityTransform.estimate(from: pts, to: pts))
    }

    func test_estimate_robustToOutliers() throws {
        // 20点中2点だけ大きく外す → 外れ値除去後の再フィットで正解に収束
        var from: [CGPoint] = []
        for i in 0..<20 {
            from.append(CGPoint(x: CGFloat(i % 5) * 20, y: CGFloat(i / 5) * 20))
        }
        var to = from.map { CGPoint(x: $0.x + 10, y: $0.y + 4) }
        to[3] = CGPoint(x: 500, y: 500)
        to[11] = CGPoint(x: -200, y: 300)
        let t = try XCTUnwrap(SimilarityTransform.estimate(from: from, to: to))
        XCTAssertEqual(t.tx, 10, accuracy: 0.5)
        XCTAssertEqual(t.ty, 4, accuracy: 0.5)
        XCTAssertEqual(t.scale, 1.0, accuracy: 0.01)
    }

    // MARK: - apply

    func test_apply_toLandmarkSet_translatesNormalizedPoints() {
        // 画像 100x200px、平行移動 (10px, 20px) → 正規化では (+0.1, +0.1)
        let set = FaceLandmarkSet(
            points: [FaceLandmark(x: 0.5, y: 0.5, z: 0.3)], confidence: 0.9)
        let t = SimilarityTransform(scale: 1, rotation: 0, tx: 10, ty: 20)
        let moved = t.apply(to: set, imageSize: CGSize(width: 100, height: 200))
        XCTAssertEqual(moved.points[0].x, 0.6, accuracy: 0.0001)
        XCTAssertEqual(moved.points[0].y, 0.6, accuracy: 0.0001)
        XCTAssertEqual(moved.points[0].z, 0.3)   // z は保持
        XCTAssertEqual(moved.confidence, 0.9)    // confidence は保持
    }

    func test_apply_toNormalizedRect_scalesAroundTransformedCenter() {
        // 2倍拡大 + 移動なし。中心(50,50)px の 20x20px 矩形 →
        // 中心(100,100)px の 40x40px 矩形（axis-aligned 近似）
        let t = SimilarityTransform(scale: 2, rotation: 0, tx: 0, ty: 0)
        let rect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let out = t.apply(toNormalizedRect: rect,
                          imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(out.midX, 1.0, accuracy: 0.0001)
        XCTAssertEqual(out.midY, 1.0, accuracy: 0.0001)
        XCTAssertEqual(out.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(out.height, 0.4, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `cd ~/Desktop/mirator/projects/Mask-Me && swift test --filter SimilarityTransformTests 2>&1 | tail -5`
Expected: コンパイルエラー（`SimilarityTransform` 未定義）

- [ ] **Step 3: 実装**

`Sources/MosaicCore/SimilarityTransform.swift`:

```swift
import CoreGraphics
import Foundation

/// フルフレームのピクセル空間で定義された2D相似変換 `p' = scale·R(rotation)·p + (tx, ty)`。
///
/// オプティカルフロー追跡（App 層の OpticalFlowTracker）が返す対応点ペアから顔の
/// フレーム間運動を推定し、最後に検出できたランドマーク一式を前進させるために使う。
/// 推定は Umeyama 法（最小二乗の相似変換フィット）+ 外れ値除去の再フィット 1 回。
/// OpenCV 非依存の純粋幾何なので MosaicCore に置き、swift test で検証する。
public struct SimilarityTransform: Sendable, Equatable {
    public let scale: CGFloat
    public let rotation: CGFloat
    public let tx: CGFloat
    public let ty: CGFloat

    public init(scale: CGFloat, rotation: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.scale = scale
        self.rotation = rotation
        self.tx = tx
        self.ty = ty
    }

    /// 対応点ペアから相似変換を推定する。
    /// - 6 ペア未満は nil（自由度 4 に対し余裕を要求）。
    /// - 1 回フィット → 残差が max(2px, 中央値の 2 倍) を超える点を除去 → 再フィット。
    ///   除去後のインライア比が 0.5 未満なら「動きが一貫していない」として nil。
    public static func estimate(from: [CGPoint], to: [CGPoint]) -> SimilarityTransform? {
        guard from.count == to.count, from.count >= 6 else { return nil }
        guard let first = fit(from: from, to: to) else { return nil }
        let residuals = zip(from, to).map { f, t -> CGFloat in
            let p = first.applyPoint(f)
            return hypot(p.x - t.x, p.y - t.y)
        }
        let sorted = residuals.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = max(2.0, median * 2.0)
        var inFrom: [CGPoint] = [], inTo: [CGPoint] = []
        for (i, r) in residuals.enumerated() where r <= threshold {
            inFrom.append(from[i])
            inTo.append(to[i])
        }
        guard inFrom.count >= 6,
              CGFloat(inFrom.count) / CGFloat(from.count) >= 0.5 else { return nil }
        return fit(from: inFrom, to: inTo)
    }

    /// Umeyama 法による最小二乗フィット（反射なし・等方スケール）。
    private static func fit(from: [CGPoint], to: [CGPoint]) -> SimilarityTransform? {
        let n = CGFloat(from.count)
        var mfx: CGFloat = 0, mfy: CGFloat = 0, mtx: CGFloat = 0, mty: CGFloat = 0
        for i in from.indices {
            mfx += from[i].x; mfy += from[i].y
            mtx += to[i].x;   mty += to[i].y
        }
        mfx /= n; mfy /= n; mtx /= n; mty /= n
        // 中心化した点で a = Σ(f·t)（内積和）, b = Σ(f×t)（外積和）, norm = Σ|f|²
        var a: CGFloat = 0, b: CGFloat = 0, norm: CGFloat = 0
        for i in from.indices {
            let fx = from[i].x - mfx, fy = from[i].y - mfy
            let tx = to[i].x - mtx,   ty = to[i].y - mty
            a += fx * tx + fy * ty
            b += fx * ty - fy * tx
            norm += fx * fx + fy * fy
        }
        guard norm > .ulpOfOne else { return nil }
        let scale = (a * a + b * b).squareRoot() / norm
        guard scale > .ulpOfOne else { return nil }
        let rotation = atan2(b, a)
        // t = mean_to − scale·R·mean_from
        let cosR = cos(rotation), sinR = sin(rotation)
        let tx = mtx - scale * (cosR * mfx - sinR * mfy)
        let ty = mty - scale * (sinR * mfx + cosR * mfy)
        return SimilarityTransform(scale: scale, rotation: rotation, tx: tx, ty: ty)
    }

    /// ピクセル空間の 1 点に変換を適用する。
    public func applyPoint(_ p: CGPoint) -> CGPoint {
        let cosR = cos(rotation), sinR = sin(rotation)
        return CGPoint(x: scale * (cosR * p.x - sinR * p.y) + tx,
                       y: scale * (sinR * p.x + cosR * p.y) + ty)
    }

    /// 正規化ランドマーク一式に適用する（ピクセル空間経由、z/confidence は保持）。
    public func apply(to set: FaceLandmarkSet, imageSize: CGSize) -> FaceLandmarkSet {
        guard imageSize.width > 0, imageSize.height > 0 else { return set }
        let moved = set.points.map { lm -> FaceLandmark in
            let p = applyPoint(CGPoint(x: CGFloat(lm.x) * imageSize.width,
                                       y: CGFloat(lm.y) * imageSize.height))
            return FaceLandmark(x: Float(p.x / imageSize.width),
                                y: Float(p.y / imageSize.height),
                                z: lm.z)
        }
        return FaceLandmarkSet(points: moved, confidence: set.confidence)
    }

    /// 正規化矩形に適用する（中心を変換しサイズを scale 倍する axis-aligned 近似）。
    public func apply(toNormalizedRect rect: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let center = applyPoint(CGPoint(x: rect.midX * imageSize.width,
                                        y: rect.midY * imageSize.height))
        let w = rect.width * imageSize.width * scale
        let h = rect.height * imageSize.height * scale
        return CGRect(x: (center.x - w / 2) / imageSize.width,
                      y: (center.y - h / 2) / imageSize.height,
                      width: w / imageSize.width,
                      height: h / imageSize.height)
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --filter SimilarityTransformTests 2>&1 | tail -3`
Expected: `Test Suite 'SimilarityTransformTests' passed`（7件）

- [ ] **Step 5: 全MosaicCoreテストが壊れていないことを確認**

Run: `swift test 2>&1 | tail -3`
Expected: 全パス（既存62件 + 新規7件）

- [ ] **Step 6: コミット**

```bash
git add Sources/MosaicCore/SimilarityTransform.swift Tests/MosaicCoreTests/SimilarityTransformTests.swift
git commit -m "MosaicCore: 相似変換の推定(Umeyama+外れ値除去)と適用を追加"
```

---

### Task 2: OpenCV導入（opencv-spm検証、フォールバック自前ビルド）

**Files:**
- Modify: `App/project.yml`（packages/dependencies追加、bridging header設定）
- Create: `App/MaskMe/MaskMe-Bridging-Header.h`

**Interfaces:**
- Produces: App/MaskMeTests両ターゲットから `#import <opencv2/...>` 可能な状態、bridging header経由でObjC++クラスがSwiftから見える状態

- [ ] **Step 1: opencv-spmのライセンスと配布物を検証**

```bash
gh repo view yeatse/opencv-spm --json licenseInfo,description,latestRelease
```
確認事項（ユーザーのライブラリ検証規約）:
1. LICENSEがApache-2.0であること
2. READMEで「公式OpenCVソースからのビルド」であることを確認（改変配布でないこと）
3. 最新リリースのxcframeworkにios-arm64-simulatorスライスが含まれること（リリースノートまたはPackage.swiftのbinaryTarget URLのzipを確認）

不合格の場合 → **Step 1-fallback** へ。合格なら Step 2 へ。

- [ ] **Step 1-fallback（opencv-spm不合格時のみ）: 最小xcframework自前ビルド**

```bash
cd /private/tmp/claude-501/-Users-tatsuki-Desktop-mirator/*/scratchpad
git clone --depth 1 --branch 4.10.0 https://github.com/opencv/opencv.git
cd opencv
python3 platforms/apple/build_xcframework.py \
  --out ./build-xcf \
  --iphoneos_archs arm64 --iphonesimulator_archs arm64,x86_64 \
  --without dnn --without ml --without photo --without stitching \
  --without gapi --without objdetect --without calib3d --without features2d \
  --without flann --without highgui --without videoio --without imgcodecs \
  --disable-bitcode
```
成果物 `opencv2.xcframework` を `Mask-Me` リポジトリのGitHub Release（タグ `opencv-4.10.0-minimal`）にアップロードし、`App/scripts/fetch-opencv.sh`（curl+チェックサム検証+`App/Vendor/`展開、Vendor/は.gitignore追加）を作成。CI dvalid.ymlのpod installステップ前に同スクリプト実行を追加。project.ymlは `dependencies: - framework: Vendor/opencv2.xcframework, embed: true` とする。以降のStepはSPM前提の記述をvendored framework前提に読み替える。

- [ ] **Step 2: project.ymlにパッケージとbridging headerを追加**

`App/project.yml` の `packages:` に追加:

```yaml
packages:
  MosaicCore:
    # The MediaPipe-free core lives one directory up as a SwiftPM package.
    path: ../
  OpenCV:
    # 疎LKオプティカルフロー（goodFeaturesToTrack + calcOpticalFlowPyrLK）専用。
    # 公式CocoaPods 'OpenCV' は4.3.0(2020)で停止しておりarm64シミュレータ非対応のため
    # 公式ソースビルドのSwiftPM binary配布を使う（Apache-2.0、Task 2 Step 1で検証済み）。
    url: https://github.com/yeatse/opencv-spm
    from: "4.10.0"   # Step 1で確認した最新安定版に合わせる
```

`MaskMe` ターゲットの `dependencies:` に `- package: OpenCV` を追加し、`settings.base` に:

```yaml
        SWIFT_OBJC_BRIDGING_HEADER: MaskMe/MaskMe-Bridging-Header.h
```

- [ ] **Step 3: bridging headerを作成**

`App/MaskMe/MaskMe-Bridging-Header.h`:

```objc
// MaskMe ターゲットの Swift ↔ ObjC++ ブリッジ。
// OpticalFlowTracker（OpenCV 疎 LK ラッパー）を Swift から見えるようにする。
#import "Model/OpticalFlowTracker.h"
```

注意: この時点ではOpticalFlowTracker.hが未作成なのでimport行はコメントアウトしておき、Task 3で有効化する。

- [ ] **Step 4: プロジェクト再生成とビルド確認**

```bash
cd ~/Desktop/mirator/projects/Mask-Me/App
xcodegen generate -q && pod install --silent
xcodebuild -workspace MaskMe.xcworkspace -scheme MaskMe \
  -destination 'platform=iOS Simulator,name=iPhone 16' build -quiet 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`（SPM解決でopencv2.xcframeworkがダウンロードされる。初回は数分かかる）

- [ ] **Step 5: コミット**

```bash
git add App/project.yml App/MaskMe/MaskMe-Bridging-Header.h
git commit -m "OpenCV 4.x をSwiftPM binaryで導入（疎LKフロー用、Apache-2.0）"
```

---

### Task 3: OpticalFlowTracker（ObjC++ラッパー、合成画像テスト）

**Files:**
- Create: `App/MaskMe/Model/OpticalFlowTracker.h`
- Create: `App/MaskMe/Model/OpticalFlowTracker.mm`
- Modify: `App/MaskMe/MaskMe-Bridging-Header.h`（import有効化）
- Test: `App/MaskMeTests/OpticalFlowTrackerTests.swift`

**Interfaces:**
- Consumes: なし（OpenCVのみ）
- Produces（Swiftから見える形）:
  - `class MMFlowMatch: NSObject { var previousPoints: [NSValue]; var currentPoints: [NSValue] }`（フルフレームのピクセル座標のCGPoint、前後方向チェック通過分のみ）
  - `class OpticalFlowTracker: NSObject { func reset(); func seed(with image: UIImage, faceBox: CGRect) -> Bool; func advance(with image: UIImage) -> MMFlowMatch? }`（faceBoxは正規化[0,1]）

- [ ] **Step 1: 失敗するテストを書く**

`App/MaskMeTests/OpticalFlowTrackerTests.swift`:

```swift
import XCTest
@testable import MaskMe

/// OpticalFlowTracker（OpenCV 疎 LK ラッパー）の合成画像テスト。
/// 実動画は使わず、決定的なパターン画像で「既知の平行移動を追跡できるか」
/// 「特徴のない画像で正直に nil を返すか」を検証する。
final class OpticalFlowTrackerTests: XCTestCase {

    /// ランダムドットパターン（seed 固定の決定的疑似乱数）を offset だけずらして描く。
    /// 市松模様は自己相似で LK が格子1マス分ズレた解に収束し得るため、非周期な
    /// ランダムドットを使う。
    private func dotsImage(size: CGSize, offset: CGPoint) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size,
            format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            var state: UInt64 = 42
            func next() -> CGFloat {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(state >> 33) / CGFloat(UInt32.max)
            }
            for _ in 0..<400 {
                let x = next() * (size.width - 20) + 10 + offset.x
                let y = next() * (size.height - 20) + 10 + offset.y
                ctx.fill(CGRect(x: x, y: y, width: 3, height: 3))
            }
        }
    }

    private func flatImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size,
            format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func test_advance_tracksKnownTranslation() throws {
        let size = CGSize(width: 320, height: 240)
        let tracker = OpticalFlowTracker()
        let seeded = tracker.seed(with: dotsImage(size: size, offset: .zero),
                                  faceBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        XCTAssertTrue(seeded)
        let match = try XCTUnwrap(
            tracker.advance(with: dotsImage(size: size, offset: CGPoint(x: 9, y: 5))))
        XCTAssertGreaterThanOrEqual(match.previousPoints.count, 15)
        // 対応点の平均移動量が仕込んだオフセットと一致するはず
        var dx: CGFloat = 0, dy: CGFloat = 0
        for (p, c) in zip(match.previousPoints, match.currentPoints) {
            dx += c.cgPointValue.x - p.cgPointValue.x
            dy += c.cgPointValue.y - p.cgPointValue.y
        }
        dx /= CGFloat(match.previousPoints.count)
        dy /= CGFloat(match.previousPoints.count)
        XCTAssertEqual(dx, 9, accuracy: 1.0)
        XCTAssertEqual(dy, 5, accuracy: 1.0)
    }

    func test_seed_failsOnFlatImage() {
        let tracker = OpticalFlowTracker()
        let seeded = tracker.seed(with: flatImage(size: CGSize(width: 320, height: 240)),
                                  faceBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        XCTAssertFalse(seeded)   // 特徴点ゼロ → seed 失敗を正直に返す
    }

    func test_advance_returnsNilWhenTargetVanishes() {
        let size = CGSize(width: 320, height: 240)
        let tracker = OpticalFlowTracker()
        XCTAssertTrue(tracker.seed(with: dotsImage(size: size, offset: .zero),
                                   faceBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)))
        // パターンが消えたフレーム → 生存点が閾値を割り nil
        XCTAssertNil(tracker.advance(with: flatImage(size: size)))
    }

    func test_advance_withoutSeed_returnsNil() {
        let tracker = OpticalFlowTracker()
        XCTAssertNil(tracker.advance(with: flatImage(size: CGSize(width: 100, height: 100))))
    }
}
```

- [ ] **Step 2: テストが失敗する（コンパイルエラーになる）ことを確認**

Run:
```bash
cd ~/Desktop/mirator/projects/Mask-Me/App
xcodebuild -workspace MaskMe.xcworkspace -scheme MaskMe \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build-for-testing -quiet 2>&1 | tail -5
```
Expected: FAIL（`OpticalFlowTracker` 未定義）

- [ ] **Step 3: ヘッダとObjC++実装を書く**

`App/MaskMe/Model/OpticalFlowTracker.h`:

```objc
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 前後方向チェックを通過した対応点ペア（フルフレームのピクセル座標）。
/// 相似変換の推定は MosaicCore.SimilarityTransform（純 Swift）側で行う。
@interface MMFlowMatch : NSObject
@property (nonatomic, readonly) NSArray<NSValue *> *previousPoints;
@property (nonatomic, readonly) NSArray<NSValue *> *currentPoints;
- (instancetype)initWithPrevious:(NSArray<NSValue *> *)previous
                         current:(NSArray<NSValue *> *)current;
@end

/// OpenCV 疎 Lucas-Kanade によるフレーム間の特徴点追跡。
/// 検出パイプラインが全滅したフレームで「画素の動き」から顔の運動を推定するための
/// 対応点ペアを供給する。OpenCV 依存はこのクラスの実装（.mm）に閉じ込める。
///
/// 品質ゲート（満たさなければ nil = フロー放棄）:
/// - 生存点 15 個以上かつ seed 時の 40% 以上
/// - 前後方向チェック: 逆追跡の往復誤差 < 2px（縮小画像空間）
/// 処理は輝度のみ・長辺 640px に縮小して行う（CI クラッシュ flaky 対策のコスト上限）。
@interface OpticalFlowTracker : NSObject
- (void)reset;
/// 検出成功フレームで呼ぶ。faceBox は正規化 [0,1]。特徴点が取れなければ NO。
- (BOOL)seedWithImage:(UIImage *)image faceBox:(CGRect)faceBox
    NS_SWIFT_NAME(seed(with:faceBox:));
/// 検出全滅フレームで呼ぶ。品質ゲート通過時のみ対応点ペアを返す。
/// 成功時は内部状態を今フレームへ前進させる（連続ギャップを追跡し続けられる）。
- (nullable MMFlowMatch *)advanceWithImage:(UIImage *)image
    NS_SWIFT_NAME(advance(with:));
@end

NS_ASSUME_NONNULL_END
```

`App/MaskMe/Model/OpticalFlowTracker.mm`:

```objc
// OpenCV ヘッダは Apple 系ヘッダより先に import する（NO マクロ衝突回避の定石）。
#import <opencv2/opencv.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/video/tracking.hpp>
#import "OpticalFlowTracker.h"

@implementation MMFlowMatch
- (instancetype)initWithPrevious:(NSArray<NSValue *> *)previous
                         current:(NSArray<NSValue *> *)current {
    if ((self = [super init])) {
        _previousPoints = previous;
        _currentPoints = current;
    }
    return self;
}
@end

namespace {
constexpr double kMaxLongSide = 640.0;   // 縮小後の長辺上限（コスト上限）
constexpr int kMaxCorners = 60;
constexpr double kQualityLevel = 0.01;
constexpr double kMinDistance = 5.0;
constexpr float kMaxFBError = 2.0f;      // 前後方向チェックの往復誤差上限（縮小px）
constexpr int kMinSurvivors = 15;
constexpr double kMinSurvivorRatio = 0.40;

/// UIImage → 縮小グレースケール cv::Mat。scaleOut に フルフレームpx / 縮小px の係数を返す。
cv::Mat grayMat(UIImage *image, double &scaleOut) {
    CGImageRef cg = image.CGImage;
    if (!cg) { scaleOut = 1.0; return cv::Mat(); }
    const size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    cv::Mat gray((int)h, (int)w, CV_8UC1);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(gray.data, w, h, 8, gray.step[0],
                                             space, kCGImageAlphaNone);
    CGColorSpaceRelease(space);
    if (!ctx) { scaleOut = 1.0; return cv::Mat(); }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    const double longSide = std::max(w, h);
    scaleOut = 1.0;
    if (longSide > kMaxLongSide) {
        scaleOut = longSide / kMaxLongSide;
        cv::Mat small;
        cv::resize(gray, small,
                   cv::Size((int)std::lround(w / scaleOut),
                            (int)std::lround(h / scaleOut)),
                   0, 0, cv::INTER_AREA);
        return small;
    }
    return gray;
}
}  // namespace

@implementation OpticalFlowTracker {
    cv::Mat _prevGray;                  // 縮小グレースケールの前フレーム
    std::vector<cv::Point2f> _points;   // 前フレームの特徴点（縮小px）
    double _scale;                      // フルフレームpx = 縮小px × _scale
    size_t _seededCount;
}

- (void)reset {
    _prevGray.release();
    _points.clear();
    _seededCount = 0;
}

- (BOOL)seedWithImage:(UIImage *)image faceBox:(CGRect)faceBox {
    double scale = 1.0;
    cv::Mat gray = grayMat(image, scale);
    if (gray.empty()) { [self reset]; return NO; }
    // 正規化 faceBox → 縮小px の ROI（画像内にクランプ）
    cv::Rect roi((int)std::lround(faceBox.origin.x * gray.cols),
                 (int)std::lround(faceBox.origin.y * gray.rows),
                 (int)std::lround(faceBox.size.width * gray.cols),
                 (int)std::lround(faceBox.size.height * gray.rows));
    roi &= cv::Rect(0, 0, gray.cols, gray.rows);
    if (roi.width < 8 || roi.height < 8) { [self reset]; return NO; }
    cv::Mat mask = cv::Mat::zeros(gray.size(), CV_8UC1);
    mask(roi).setTo(255);
    std::vector<cv::Point2f> corners;
    cv::goodFeaturesToTrack(gray, corners, kMaxCorners, kQualityLevel,
                            kMinDistance, mask);
    if ((int)corners.size() < kMinSurvivors) { [self reset]; return NO; }
    _prevGray = gray;
    _points = corners;
    _scale = scale;
    _seededCount = corners.size();
    return YES;
}

- (nullable MMFlowMatch *)advanceWithImage:(UIImage *)image {
    if (_prevGray.empty() || _points.empty()) { return nil; }
    double scale = 1.0;
    cv::Mat gray = grayMat(image, scale);
    if (gray.empty() || gray.size() != _prevGray.size()) { [self reset]; return nil; }

    std::vector<cv::Point2f> next, back;
    std::vector<uchar> stF, stB;
    std::vector<float> err;
    const cv::Size win(21, 21);
    cv::calcOpticalFlowPyrLK(_prevGray, gray, _points, next, stF, err, win, 3);
    // 前後方向チェック: next を逆向きに追跡して元の点に戻るか
    cv::calcOpticalFlowPyrLK(gray, _prevGray, next, back, stB, err, win, 3);

    NSMutableArray<NSValue *> *prevOut = [NSMutableArray array];
    NSMutableArray<NSValue *> *currOut = [NSMutableArray array];
    std::vector<cv::Point2f> survivors;
    for (size_t i = 0; i < _points.size(); i++) {
        if (!stF[i] || !stB[i]) { continue; }
        const float fb = cv::norm(back[i] - _points[i]);
        if (fb > kMaxFBError) { continue; }
        survivors.push_back(next[i]);
        // フルフレームpx へ戻して出力（相似変換の推定は Swift 側）
        [prevOut addObject:[NSValue valueWithCGPoint:
            CGPointMake(_points[i].x * _scale, _points[i].y * _scale)]];
        [currOut addObject:[NSValue valueWithCGPoint:
            CGPointMake(next[i].x * scale, next[i].y * scale)]];
    }
    const bool pass = (int)survivors.size() >= kMinSurvivors &&
        (double)survivors.size() / (double)_seededCount >= kMinSurvivorRatio;
    if (!pass) { [self reset]; return nil; }
    // 状態を今フレームへ前進（連続ギャップでも追跡を継続できる）
    _prevGray = gray;
    _points = survivors;
    _scale = scale;
    return [[MMFlowMatch alloc] initWithPrevious:prevOut current:currOut];
}

@end
```

`App/MaskMe/MaskMe-Bridging-Header.h` のimport行を有効化。

- [ ] **Step 4: プロジェクト再生成してテスト実行**

```bash
cd ~/Desktop/mirator/projects/Mask-Me/App
xcodegen generate -q && pod install --silent
xcodebuild -workspace MaskMe.xcworkspace -scheme MaskMe \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test -only-testing:MaskMeTests/OpticalFlowTrackerTests -quiet 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`（4件パス）

- [ ] **Step 5: コミット**

```bash
git add App/MaskMe/Model/OpticalFlowTracker.h App/MaskMe/Model/OpticalFlowTracker.mm \
        App/MaskMe/MaskMe-Bridging-Header.h App/MaskMeTests/OpticalFlowTrackerTests.swift
git commit -m "OpticalFlowTracker: 疎LK+前後方向チェックの対応点追跡ラッパー"
```

---

### Task 4: Adapter統合（flowソース + track前進）

**Files:**
- Modify: `App/MaskMe/Model/MediaPipeFaceLandmarkerAdapter.swift`
  - `FaceDetectionSource`（40行付近）に `case flow` 追加
  - `FaceDetectionSourceStats`（51行付近）に `flowFrames` 追加
  - `recordSource`（128行付近）に `.flow` 分岐追加
  - テンポラル追跡の状態群（89行付近）にフロー状態を追加
  - `allLandmarks(in:timestampMs:)`（229行付近）にフロー発動とseedを追加
  - `resetTracksIfNeeded` にフロー状態リセットを追加

**Interfaces:**
- Consumes: `OpticalFlowTracker.seed(with:faceBox:)` / `.advance(with:)`（Task 3）、`SimilarityTransform.estimate/apply`（Task 1）
- Produces: `FaceDetectionSource.flow`（rawValue `"flow"`）、`FaceDetectionSourceStats.flowFrames`。DValidテスト（Task 5）はこの2つを参照する

- [ ] **Step 1: enum/stats/recordSourceを拡張**

```swift
public enum FaceDetectionSource: String {
    case mp          // MediaPipe FaceLandmarker 本検出（enhance なし）
    case enhance = "enh"  // enhance（moderate/aggressive/backlight）後に検出
    case bbox        // 補助検出器 bbox → ROI 再検出のみが拾った
    case roi         // テンポラル ROI 再検出（前フレーム bbox）
    case lowConf = "low"  // 低 confidence 最終フォールバック
    case tiled = "tile"   // タイル分割再検出（track なしの長期ロスト用）
    case flow        // オプティカルフロー・ブリッジ（検出ではなく追跡による補完）
    case none = ""   // 未検出
}
```

`FaceDetectionSourceStats` に `public var flowFrames = 0` を追加。
`recordSource` の switch に `case .flow: sourceStats.flowFrames += 1` を追加。

- [ ] **Step 2: フロー状態と発動ロジックを追加**

`trackedFaces` 宣言の直後に:

```swift
    // MARK: - オプティカルフロー・ブリッジ（video モード専用）
    //
    // 検出パイプライン全段（MP → enhance → bbox → ROI → lowConf → タイル → 顔検証）が
    // 全滅したフレームを、OpenCV 疎 LK の「画素の動き」でブリッジする。検出器は
    // 「顔らしい見た目」が消えたフレーム（横顔・後ろ向き・強ブレ・極暗）で原理的に
    // 全滅するが、フローは顔かどうかを見ないため位置の供給を続けられる。
    //
    // 出力は src=flow でタグ付けし、rate（生検出率）には算入しない（DValid 側で区別）。
    // フローは顔の存在を証明しないため、trackedFaces の missCount には触らない。
    private struct FlowState {
        let tracker: OpticalFlowTracker
        var lastLandmarks: FaceLandmarkSet
    }
    private var flowStates: [FlowState] = []
    /// 連続フロー供給の上限フレーム数（15fps サンプリングで 30 ≒ 2 秒）。
    /// ドリフト（ズレの蓄積）で実顔から外れたまま供給し続けるのを防ぐ。
    private let maxFlowFrames = 30
    private let maxFlowTracks = 3
    private var consecutiveFlowFrames = 0
```

`allLandmarks(in:timestampMs:)` の顔検証パスブロック（`if !result.isEmpty { let verified = ... }`）の**直後・`recordSource(source)` の直前**に:

```swift
        if result.isEmpty, !flowStates.isEmpty, consecutiveFlowFrames < maxFlowFrames {
            // 検出全滅 → フローで前回ランドマークを前進させてブリッジする。
            // 顔検証パス（タイト crop 再検出）は「検出器で見える顔」しか通せないため、
            // フロー出力には適用しない（検出器が全滅したからこそフローに来ている）。
            // 誤検出の延命は品質ゲート・上限フレーム・lowCy 番犬の3重で抑える。
            let imageSize = pixelSize(of: image)
            var flowFaces: [FaceLandmarkSet] = []
            var survivors: [FlowState] = []
            for var state in flowStates {
                guard let match = state.tracker.advance(with: image),
                      let transform = SimilarityTransform.estimate(
                          from: match.previousPoints.map(\.cgPointValue),
                          to: match.currentPoints.map(\.cgPointValue)),
                      (0.7...1.4).contains(transform.scale) else { continue }
                let moved = transform.apply(to: state.lastLandmarks, imageSize: imageSize)
                state.lastLandmarks = moved
                flowFaces.append(moved)
                survivors.append(state)
                // 対応する track の bbox も前進させ、次フレームの ROI 再検出が
                // フロー予測位置を走査できるようにする（実顔再取得の早期化）。
                let movedBox = moved.boundingBox
                if let ti = trackedFaces.indices.max(by: {
                    iou(trackedFaces[$0].box, movedBox) < iou(trackedFaces[$1].box, movedBox)
                }), iou(trackedFaces[ti].box, movedBox) > 0.1 {
                    trackedFaces[ti].box = movedBox
                }
            }
            flowStates = survivors
            if !flowFaces.isEmpty {
                result = flowFaces
                source = .flow
                consecutiveFlowFrames += 1
            }
        } else if result.isEmpty {
            flowStates = []
        }
        if !result.isEmpty, source != .flow {
            // 実検出（どのソースでも）に成功したらフローを再シードする。
            // seed は縮小 ROI の特徴点抽出のみで軽量（〜1ms）なので毎フレーム行う。
            consecutiveFlowFrames = 0
            flowStates = result.prefix(maxFlowTracks).compactMap { face in
                let tracker = OpticalFlowTracker()
                guard tracker.seed(with: image, faceBox: face.boundingBox) else { return nil }
                return FlowState(tracker: tracker, lastLandmarks: face)
            }
        }
```

ヘルパー（`iou` の近くに追加）:

```swift
    /// UIImage のピクセル寸法（UIImage.size はポイント単位で scale 依存のため CGImage を使う）。
    private func pixelSize(of image: UIImage) -> CGSize {
        guard let cg = image.cgImage else { return image.size }
        return CGSize(width: cg.width, height: cg.height)
    }
```

`resetTracksIfNeeded` 内の track リセット処理に `flowStates = []` と `consecutiveFlowFrames = 0` を追加。ファイル冒頭に `import MosaicCore`（既にあれば不要）。

- [ ] **Step 3: ビルドと既存テストの確認**

```bash
cd ~/Desktop/mirator/projects/Mask-Me/App
xcodebuild -workspace MaskMe.xcworkspace -scheme MaskMe \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test -only-testing:MaskMeTests/OpticalFlowTrackerTests \
       -only-testing:MaskMeTests/DetectionAccuracyTests -quiet 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`（フィクスチャ静止画テストは1フレームずつ独立なのでフロー無発動＝挙動不変）

- [ ] **Step 4: コミット**

```bash
git add App/MaskMe/Model/MediaPipeFaceLandmarkerAdapter.swift
git commit -m "Adapter: 検出全滅フレームをオプティカルフローでブリッジ(src=flow)"
```

---

### Task 5: DValid計測拡張（flowRate + Aggregate列）

**Files:**
- Modify: `App/MaskMeTests/DValidVideoTests.swift`（69-175行の `run` メソッド）
- Modify: `.github/workflows/dvalid.yml`（227行以降のAggregate python）

**Interfaces:**
- Consumes: `lastSource.rawValue == "flow"`、`sourceStats.flowFrames`（Task 4）
- Produces: DVALRESULTの `"flowHit"` / `"flowRate"` / `"srcFlow"` キー（Task 6-7のプローブ・CI比較が参照）

- [ ] **Step 1: rateからflowを除外しflowHitを追加**

`run` メソッドの計測変数に `var flowHit = 0` を追加し、ヒット分岐を変更:

```swift
                    let faces = scanner.allLandmarks(in: img, timestampMs: Int(t * 1000))
                    let src = (scanner as? MediaPipeFaceLandmarkerAdapter)?.lastSource.rawValue ?? ""
                    if let first = faces.first {
                        // rate（生検出率）の定義は従来どおり「検出器が見つけた」フレームのみ。
                        // フロー供給フレームは追跡による補完なので flowHit のみに数え、
                        // 1 回の CI ランで rate（波及効果）と flowRate（フロー込み）を
                        // 同時に計測する自己対照にする。
                        if src != FaceDetectionSource.flow.rawValue { hit += 1 }
                        flowHit += 1
                        detectionCache[t] = faces
```

（`lowCy` / jump系 / `detectionCache` / DVALFRAME出力はフロー込みのまま = 番犬とbridgedRateはアプリ挙動どおり計測される）

- [ ] **Step 2: DVALRESULTに3キー追加**

`resultLine` の `"bridgedRate10":\(bridgedRate10)` の後に追加:

```swift
        let flowRate = total == 0 ? 0.0 : Double(flowHit) / Double(total)
```

```
,"flowHit":\(flowHit),"flowRate":\(flowRate),"srcFlow":\(stats.flowFrames)
```

（既存の `srcTile` の後に `srcFlow` を並べる）

- [ ] **Step 3: Aggregateに flow 列を追加**

`.github/workflows/dvalid.yml` のAggregate python:
- `merged` の初期値dictに `'flowHit': 0, 'srcFlow': 0` を追加
- 合算ループに `m['flowHit'] += d.get('flowHit', 0)` と `m['srcFlow'] += d.get('srcFlow', 0)` を追加
- ヘッダ行を `| 動画 | backend | half | hit | total | rate | flow | baseline | Δ | bridged | ... | src mp/enh/bbox/roi/low/tile/flow |` に変更（`flow` 列と `srcFlow` を追加、区切り行の `---` も1本増やす）
- 行生成に:

```python
              flow_rate = (m['flowHit'] / total * 100) if total else 0.0
```

を追加し、出力fstringのrateの後に `| {flow_rate:.1f}% ` を、`srcs` を `f"...{m['srcTile']}/{m['srcFlow']}"` に変更

- [ ] **Step 4: ローカルでビルド確認（XCTSkip経路）**

```bash
cd ~/Desktop/mirator/projects/Mask-Me/App
xcodebuild -workspace MaskMe.xcworkspace -scheme MaskMe \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build-for-testing -quiet 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: コミット**

```bash
git add App/MaskMeTests/DValidVideoTests.swift .github/workflows/dvalid.yml
git commit -m "DValid: flowRate計測を追加（rateはフロー除外の自己対照設計）"
```

---

### Task 6: ローカルプローブ + パラメータ調整

**Files:** なし（計測。調整が必要な場合のみ `OpticalFlowTracker.mm` の定数 / `maxFlowFrames` を変更）

**Interfaces:**
- Consumes: DVALRESULTの `flowRate` / `lowCy` / `avgJump`（Task 5）

- [ ] **Step 1: サンプル動画の準備確認**

```bash
ls /tmp/samples/*.mov 2>/dev/null || echo "MISSING"
```
MISSINGなら前セッションと同様に `gdown --folder` でDL（`.claude-handoff.md` のワークフロー欄参照）。

- [ ] **Step 2: build-for-testing（1回だけ）**

```bash
cd ~/Desktop/mirator/projects/Mask-Me/App
xcodebuild -workspace MaskMe.xcworkspace -scheme MaskMe \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  SAMPLE_VIDEO_DIR=/tmp/samples build-for-testing -quiet 2>&1 | tail -3
```

- [ ] **Step 3: プローブ3本実行**

対象: `test_S4_off_A`（最長ギャップ・最大の伸びしろ）/ `test_S1_off_B`（リグレッション監視）/ `test_S5_off_A`（lowCy番犬）

```bash
for T in test_S4_off_A test_S1_off_B test_S5_off_A; do
  xcodebuild -workspace MaskMe.xcworkspace -scheme MaskMe \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    SAMPLE_VIDEO_DIR=/tmp/samples test-without-building \
    -only-testing:MaskMeTests/DValidVideoTests/$T 2>&1 | grep DVALRESULT
done
```

- [ ] **Step 4: 判定と調整**

PR #14確定値（off backend・該当ハーフ）と比較:
- s4_A: `flowRate > rate` が成立し、flowRateが従来rate比 +3pp 以上あるか
- s1_B: `rate` が 68.2% から悪化していないか（フローのtrack前進の副作用監視）
- s5_A: `lowCy` が 68（顔検証パス後の確定値）から増えていないか、avgJump悪化なし

不合格の場合の調整レバー（1回の変更は1レバーのみ、再プローブで確認）:
- lowCy増 → `maxFlowFrames` 30→15、または `kMinSurvivorRatio` 0.40→0.55
- flowRate伸びず → `kMaxFBError` 2.0→3.0（緩和）、`maxFlowFrames` 30→45
- avgJump悪化 → `SimilarityTransform.estimate` のインライア比下限 0.5→0.65

3回調整しても番犬が収まらない場合は中断してユーザーに報告（グローバル規定のループ防止）。

- [ ] **Step 5: 調整があればコミット**

```bash
git add -A App/MaskMe Sources
git commit -m "フローブリッジのパラメータ調整（プローブ結果: <数値を記載>）"
```

---

### Task 7: CIフルラン → 比較表 → 採否判断

**Files:**
- Modify: `.claude-handoff.md`（結果記録）
- Modify: `docs/superpowers/specs/2026-07-04-optical-flow-tracking-design.md`（実装詳細変更2点の追記）
- Modify: `~/Desktop/mirator/.ai-company/projects/Mask-Me.md`（PJ記録、git管理外）

**Interfaces:**
- Consumes: Aggregateサマリの `flow` 列（Task 5）、PR #14確定表（スペック内baseline）

- [ ] **Step 1: push + CI起動**

```bash
cd ~/Desktop/mirator/projects/Mask-Me
git push -u origin feature/optical-flow-tracking
gh workflow run dvalid.yml --ref feature/optical-flow-tracking
```
Monitorスクリプトで完走を監視（zshの `status` 変数は使わない。`st` を使う）。クラッシュ型flakyはrun完走後に `gh run rerun --failed`（別VMガチャ）。

- [ ] **Step 2: 比較表を作成**

Aggregate結果とスペック内のPR #14確定表から、動画ごとに rate / flowRate / bridgedRate / lowCy% / jumpBig% / ジョブ時間 の before→after 表を作る。3 backendの一致も確認（フローはbackend非依存レイヤーなのでoff/faceDetector/yunetで同傾向のはず）。

- [ ] **Step 3: 採否判定**

スペックの勝敗ライン:
- **勝ち**（s1/s4/s5いずれかで bridgedRate +3pp以上 かつ 番犬クリア かつ ジョブ90分内）→ Step 4a
- **負け** → Step 4b

- [ ] **Step 4a: 採用 — ship**

1. スペックに実装詳細変更2点（本計画冒頭）を追記
2. `.claude-handoff.md` に確定値・設計・教訓を追記
3. shipスキル（lint/build/test green → PR作成）。PR本文に比較表・残課題（部分ビルドによるバイナリサイズ最適化、実機確認）を記載
4. PJ記録とNotionナレッジ（「動画メディア処理ノウハウ集」ページ）に「検出器の限界を追跡で補完する」知見を追記
5. PushNotificationで完了報告

- [ ] **Step 4b: 撤退 — 記録を残して閉じる**

1. `.claude-handoff.md` と PJ記録に「試した構成・確定数値・敗因分析」を記録
2. Notionナレッジに教訓を追記（負けた実験も再発防止の資産）
3. ブランチはpush済みのまま残し、PRは作らない。ユーザーに数値付きで報告

---

## Self-Review 済み

- スペック全要件（方式A・品質ゲート・上限30・track前進・3指標・番犬・勝敗ライン・テスト3層）にタスクが対応
- 型整合: `MMFlowMatch.previousPoints/currentPoints`（Task 3）→ Task 4 の `match.previousPoints.map(\.cgPointValue)`、`SimilarityTransform.estimate/apply`（Task 1）→ Task 4、`FaceDetectionSource.flow.rawValue == "flow"`（Task 4）→ Task 5
- スペックとの差分2点は冒頭に明記し、Task 7でスペックへ反映する
