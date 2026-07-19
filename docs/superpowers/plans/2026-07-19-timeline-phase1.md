# タイムライン編集 フェーズ1 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 動画編集の内部基盤をクリップ列 + AVMutableComposition に置き換え、検出キャッシュのキーを素材基準にする。画面の見た目と挙動は一切変えない。

**Architecture:** 「ソース動画1本」を `TimelineClip` の列に置き換え、`AVMutableComposition` で1本の時間軸に合成する。`AVMutableComposition` は `AVAsset` のサブクラスなので、プレビューの `AVPlayerItem` も書き出しの `AVAssetReader` も合成結果をそのまま扱える。検出キャッシュのキーは合成時刻から `(素材ID, 素材内時刻)` に変更し、将来のクリップ編集で検出結果が失われないようにする。

**Tech Stack:** Swift 5, SwiftUI, AVFoundation, Metal, MediaPipe, XCTest, SwiftPM (MosaicCore), CocoaPods, XcodeGen

## Global Constraints

- SwiftLint: `file_length` 500 行、`type_body_length` 300 行を超えないこと
- 4要素以上のタプルは使わず struct にすること
- **`SAMPLE_VIDEO_DIR` を設定しないこと。** `SampleFalsePositiveTests` / `DiagLivePathDumpTests` / `DValidLiveModelTests` は実行しないこと
- `main` へ直接 push しないこと。作業は `feat/timeline-phase1` ブランチで行い、PR 経由でマージすること
- 新規ファイルを追加したら `xcodegen generate` と `LANG=en_US.UTF-8 pod install` を実行すること
- bash コマンドは毎回 `cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me &&` を明示すること（作業ディレクトリがリセットされる既知の問題があるため）
- **テスト成功の判定は「TEST SUCCEEDED」の表示だけを根拠にしないこと。** 実行されたテストケース数を必ず確認すること（過去にビルドキャッシュが古く、新規テストが1件も走らないまま成功表示が出た事故があった）
- 単一クリップの場合も必ず Composition を経由させ、特別扱いの分岐を作らないこと
- フェーズ1では画面の見た目・操作・書き出し結果を変えないこと

## 前提: 作業ブランチの作成

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && git fetch origin && git checkout main && git pull origin main && git checkout -b feat/timeline-phase1
```

---

## ファイル構成

**新規作成**
- `Sources/MosaicCore/Timeline/TimelineClip.swift` — クリップのデータ構造（AVFoundation 非依存）
- `Sources/MosaicCore/Timeline/DetectionCacheKey.swift` — 検出キャッシュのキー
- `Sources/MosaicCore/Timeline/TimelineMapping.swift` — 合成時刻 ⇄ 素材時刻の変換（純粋計算）
- `Sources/MosaicCore/Timeline/DetectionCacheStore.swift` — キー付きキャッシュの保管庫
- `MaskMe/Model/TimelineCompositionBuilder.swift` — クリップ列から `AVMutableComposition` を構築
- `Tests/MosaicCoreTests/TimelineMappingTests.swift`
- `Tests/MosaicCoreTests/DetectionCacheStoreTests.swift`
- `MaskMeTests/TimelineCompositionBuilderTests.swift`

**変更**
- `MaskMe/Model/MosaicEditorModel.swift` — `detectionCache` をキー付きに移行、クリップ列を保持
- `MaskMe/Model/MosaicPreviewController.swift:78` — `url: URL` 受け取りを `AVAsset` 受け取りに変更
- `MaskMe/Export/VideoMosaicExporter.swift:128` — `detectionCache` の型変更に追随

`MosaicCore` 側は AVFoundation に依存させない。`swift test` で高速にテストできる状態を保つ。

---

### Task 1: クリップと検出キャッシュキーのデータ構造

**Files:**
- Create: `Sources/MosaicCore/Timeline/TimelineClip.swift`
- Create: `Sources/MosaicCore/Timeline/DetectionCacheKey.swift`
- Test: `Tests/MosaicCoreTests/TimelineMappingTests.swift`（Task 2 で使う。ここでは作らない）

**Interfaces:**
- Consumes: なし
- Produces: `TimelineClip`（`id: UUID`, `sourceID: UUID`, `sourceStart: Double`, `sourceEnd: Double`, `duration: Double`, `originalAudioVolume: Float`）、`DetectionCacheKey`（`sourceID: UUID`, `bucket: Double`, `init(sourceID:time:bucketFPS:)`）

- [ ] **Step 1: TimelineClip を作る**

`Sources/MosaicCore/Timeline/TimelineClip.swift`:

```swift
import Foundation

/// タイムライン上の1クリップ。素材（動画ファイル）の一部分を指す。
///
/// `sourceID` は素材の識別子であり、クリップの識別子ではない。
/// 1つの素材を分割して2つのクリップになった場合、両者は同じ `sourceID` を持つ。
/// 検出キャッシュを素材単位で共有するための設計である。
public struct TimelineClip: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// 素材の識別子。分割しても変わらない。
    public let sourceID: UUID
    /// 素材内での使用開始位置（秒）。
    public var sourceStart: Double
    /// 素材内での使用終了位置（秒）。
    public var sourceEnd: Double
    /// 元音声の音量（0...1）。フェーズ4で UI から調整可能にする。
    public var originalAudioVolume: Float

    public init(id: UUID = UUID(),
                sourceID: UUID,
                sourceStart: Double,
                sourceEnd: Double,
                originalAudioVolume: Float = 1.0) {
        self.id = id
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.originalAudioVolume = originalAudioVolume
    }

    /// このクリップが合成タイムライン上で占める長さ（秒）。
    /// 速度変更は非対応のため、素材内の長さと等しい。
    public var duration: Double { max(0, sourceEnd - sourceStart) }
}
```

- [ ] **Step 2: DetectionCacheKey を作る**

`Sources/MosaicCore/Timeline/DetectionCacheKey.swift`:

```swift
import Foundation

/// 検出キャッシュのキー。素材内の時刻でキーする。
///
/// 合成後の時刻でキーすると、クリップを1つ削除・並べ替えただけで
/// 後続クリップの時刻が全てずれ、検出済みの顔情報が全て無効になる。
/// 素材基準でキーすることで、分割・削除・並べ替えのいずれでも
/// 検出結果が失われない。
public struct DetectionCacheKey: Hashable, Sendable {
    public let sourceID: UUID
    /// 素材内での時刻を bucketFPS で丸めた値。
    public let bucket: Double

    public init(sourceID: UUID, bucket: Double) {
        self.sourceID = sourceID
        self.bucket = bucket
    }

    /// 素材内の生の時刻からキーを作る。時刻はバケットに丸められる。
    ///
    /// 丸めを init に閉じ込めることで、呼び出し側が丸め忘れて
    /// 別エントリを作ってしまう事故を防ぐ（過去にプリスキャンと
    /// ライブ検出でキーがずれ、同一時刻が2エントリに分裂した回帰がある）。
    public init(sourceID: UUID, time: Double, bucketFPS: Double) {
        self.sourceID = sourceID
        self.bucket = (time * bucketFPS).rounded() / bucketFPS
    }
}
```

- [ ] **Step 3: ビルドが通ることを確認**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && swift build 2>&1 | tail -5
```

Expected: エラーなく完了（`Compiling MosaicCore` の後にエラー行が出ないこと）

- [ ] **Step 4: コミット**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && git add Sources/MosaicCore/Timeline/ && git commit -m "feat: タイムラインのクリップと検出キャッシュキーを定義

検出キャッシュのキーを素材基準にすることで、クリップの分割・削除・
並べ替えをしても検出結果が失われないようにする土台。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: 合成時刻 ⇄ 素材時刻の変換層

**Files:**
- Create: `Sources/MosaicCore/Timeline/TimelineMapping.swift`
- Test: `Tests/MosaicCoreTests/TimelineMappingTests.swift`

**Interfaces:**
- Consumes: `TimelineClip`（Task 1）
- Produces: `TimelineMapping`（`init(clips:)`, `totalDuration: Double`, `sourceLocation(at:) -> SourceLocation?`, `compositionTime(clipID:sourceTime:) -> Double?`, `clipStartTime(clipID:) -> Double?`）、`TimelineMapping.SourceLocation`（`clipID: UUID`, `sourceID: UUID`, `time: Double`）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MosaicCoreTests/TimelineMappingTests.swift`:

```swift
import XCTest
@testable import MosaicCore

final class TimelineMappingTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    /// クリップA(素材Aの0-3秒) + クリップB(素材Bの10-14秒) の並び。
    private func makeMapping() -> (TimelineMapping, TimelineClip, TimelineClip) {
        let a = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let b = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)
        return (TimelineMapping(clips: [a, b]), a, b)
    }

    func test_totalDurationIsSumOfClips() {
        let (mapping, _, _) = makeMapping()
        XCTAssertEqual(mapping.totalDuration, 7, accuracy: 1e-9)
    }

    /// 先頭クリップ内の時刻は、そのまま素材時刻になる。
    func test_firstClipMapsDirectly() {
        let (mapping, a, _) = makeMapping()
        let loc = mapping.sourceLocation(at: 1.5)
        XCTAssertEqual(loc?.clipID, a.id)
        XCTAssertEqual(loc?.sourceID, sourceA)
        XCTAssertEqual(loc?.time ?? 0, 1.5, accuracy: 1e-9)
    }

    /// 2つ目のクリップでは、素材内のオフセット(10秒)が加算される。
    /// ここがずれると、後続クリップの検出結果が全て別時刻を引く。
    func test_secondClipAppliesSourceOffset() {
        let (mapping, _, b) = makeMapping()
        let loc = mapping.sourceLocation(at: 4.0)  // クリップBの先頭から1秒
        XCTAssertEqual(loc?.clipID, b.id)
        XCTAssertEqual(loc?.sourceID, sourceB)
        XCTAssertEqual(loc?.time ?? 0, 11.0, accuracy: 1e-9)
    }

    /// クリップ境界は次のクリップの先頭に属する（半開区間 [start, end)）。
    /// 境界の扱いが曖昧だと、1フレームだけ前のクリップの顔が出る不具合になる。
    func test_boundaryBelongsToNextClip() {
        let (mapping, _, b) = makeMapping()
        let loc = mapping.sourceLocation(at: 3.0)
        XCTAssertEqual(loc?.clipID, b.id)
        XCTAssertEqual(loc?.time ?? 0, 10.0, accuracy: 1e-9)
    }

    /// 範囲外は nil。末尾ちょうども範囲外とする。
    func test_outOfRangeReturnsNil() {
        let (mapping, _, _) = makeMapping()
        XCTAssertNil(mapping.sourceLocation(at: -0.1))
        XCTAssertNil(mapping.sourceLocation(at: 7.0))
        XCTAssertNil(mapping.sourceLocation(at: 99))
    }

    /// 素材時刻から合成時刻への逆変換。
    func test_reverseMapping() {
        let (mapping, _, b) = makeMapping()
        let t = mapping.compositionTime(clipID: b.id, sourceTime: 11.0)
        XCTAssertEqual(t ?? 0, 4.0, accuracy: 1e-9)
    }

    /// クリップの使用範囲外の素材時刻は逆変換できない。
    func test_reverseMappingRejectsTimeOutsideClip() {
        let (mapping, _, b) = makeMapping()
        XCTAssertNil(mapping.compositionTime(clipID: b.id, sourceTime: 20.0))
    }

    /// 空のタイムラインで破綻しないこと。
    func test_emptyTimeline() {
        let mapping = TimelineMapping(clips: [])
        XCTAssertEqual(mapping.totalDuration, 0)
        XCTAssertNil(mapping.sourceLocation(at: 0))
    }

    /// 同じ素材を分割した2クリップは、同じ sourceID を返す。
    /// これが成立しないと分割時に検出キャッシュを共有できない。
    func test_splitClipsShareSourceID() {
        let first = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 2)
        let second = TimelineClip(sourceID: sourceA, sourceStart: 2, sourceEnd: 5)
        let mapping = TimelineMapping(clips: [first, second])

        XCTAssertEqual(mapping.sourceLocation(at: 1.0)?.sourceID, sourceA)
        XCTAssertEqual(mapping.sourceLocation(at: 3.0)?.sourceID, sourceA)
        // 合成時刻3.0 はクリップ2の先頭から1秒 = 素材時刻3.0
        XCTAssertEqual(mapping.sourceLocation(at: 3.0)?.time ?? 0, 3.0, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && swift test --filter TimelineMappingTests 2>&1 | tail -20
```

Expected: FAIL。`cannot find 'TimelineMapping' in scope` というコンパイルエラー

- [ ] **Step 3: TimelineMapping を実装する**

`Sources/MosaicCore/Timeline/TimelineMapping.swift`:

```swift
import Foundation

/// 合成タイムライン上の時刻と、素材内の時刻を相互変換する。
///
/// この変換を一箇所に閉じ込めることで、既存の時刻ベース API
/// （`lookupFaces(at:)` など）の呼び出し側の構造を変えずに済む。
public struct TimelineMapping: Sendable {
    /// 合成時刻がどのクリップのどの素材時刻に対応するかを表す。
    public struct SourceLocation: Equatable, Sendable {
        public let clipID: UUID
        public let sourceID: UUID
        /// 素材内での時刻（秒）。
        public let time: Double

        public init(clipID: UUID, sourceID: UUID, time: Double) {
            self.clipID = clipID
            self.sourceID = sourceID
            self.time = time
        }
    }

    /// クリップと、その合成タイムライン上の開始位置。
    private struct Entry {
        let clip: TimelineClip
        let start: Double
    }

    private let entries: [Entry]
    public let totalDuration: Double

    public init(clips: [TimelineClip]) {
        var acc = 0.0
        var built: [Entry] = []
        built.reserveCapacity(clips.count)
        for clip in clips {
            built.append(Entry(clip: clip, start: acc))
            acc += clip.duration
        }
        self.entries = built
        self.totalDuration = acc
    }

    /// 合成時刻 → 素材内の位置。範囲外なら nil。
    ///
    /// クリップ境界は次のクリップに属する（半開区間 [start, end)）。
    public func sourceLocation(at compositionTime: Double) -> SourceLocation? {
        guard compositionTime >= 0, compositionTime < totalDuration else { return nil }
        for entry in entries {
            let end = entry.start + entry.clip.duration
            if compositionTime < end {
                let offset = compositionTime - entry.start
                return SourceLocation(clipID: entry.clip.id,
                                      sourceID: entry.clip.sourceID,
                                      time: entry.clip.sourceStart + offset)
            }
        }
        return nil
    }

    /// 素材内の時刻 → 合成時刻。
    /// そのクリップの使用範囲外の素材時刻を渡した場合は nil。
    public func compositionTime(clipID: UUID, sourceTime: Double) -> Double? {
        guard let entry = entries.first(where: { $0.clip.id == clipID }) else { return nil }
        let offset = sourceTime - entry.clip.sourceStart
        guard offset >= 0, offset <= entry.clip.duration else { return nil }
        return entry.start + offset
    }

    /// クリップの合成タイムライン上の開始位置。
    public func clipStartTime(clipID: UUID) -> Double? {
        entries.first(where: { $0.clip.id == clipID })?.start
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && swift test --filter TimelineMappingTests 2>&1 | tail -20
```

Expected: PASS。**実行されたテスト数が 9 であることを確認する**（`Executed 9 tests` の行を目視）

- [ ] **Step 5: コミット**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && git add Sources/MosaicCore/Timeline/TimelineMapping.swift Tests/MosaicCoreTests/TimelineMappingTests.swift && git commit -m "feat: 合成時刻と素材時刻の変換層を追加

クリップ境界は半開区間で次のクリップに属する。境界の扱いが曖昧だと
1フレームだけ前のクリップの顔が出る不具合になるため、テストで固定した。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: 検出キャッシュの保管庫

**Files:**
- Create: `Sources/MosaicCore/Timeline/DetectionCacheStore.swift`
- Test: `Tests/MosaicCoreTests/DetectionCacheStoreTests.swift`

**Interfaces:**
- Consumes: `DetectionCacheKey`（Task 1）, `TimelineMapping`（Task 2）, `FaceLandmarkSet`（既存）
- Produces: `DetectionCacheStore`（`init(bucketFPS:)`, `store(_:sourceID:time:)`, `faces(sourceID:time:) -> [FaceLandmarkSet]?`, `nearestFaces(sourceID:time:window:) -> [FaceLandmarkSet]`, `hasEntry(sourceID:time:) -> Bool`, `removeAll()`, `removeAll(sourceID:)`, `count: Int`, `isEmpty: Bool`, `allEntries: [DetectionCacheKey: [FaceLandmarkSet]]`）

- [ ] **Step 1: 失敗するテストを書く**

`Tests/MosaicCoreTests/DetectionCacheStoreTests.swift`:

```swift
import XCTest
@testable import MosaicCore

final class DetectionCacheStoreTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    private func face(cx: Float) -> FaceLandmarkSet {
        FaceLandmarkSet(points: [
            FaceLandmark(x: cx - 0.05, y: 0.4),
            FaceLandmark(x: cx + 0.05, y: 0.4),
            FaceLandmark(x: cx - 0.05, y: 0.6),
            FaceLandmark(x: cx + 0.05, y: 0.6)
        ], confidence: 1)
    }

    func test_storeAndRetrieve() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        XCTAssertEqual(store.faces(sourceID: sourceA, time: 1.0)?.count, 1)
    }

    /// 同一バケットに丸められる時刻は同じエントリを指すこと。
    /// 浮動小数の累積誤差でキーが分裂した回帰があるため明示的に検証する。
    func test_nearbyTimesShareBucket() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        // 1/15 秒の 1/100 だけずれた時刻は同じバケット
        XCTAssertNotNil(store.faces(sourceID: sourceA, time: 1.0 + (1.0 / 15.0) * 0.01))
        XCTAssertEqual(store.count, 1)
    }

    /// 素材が違えば別エントリになること。
    func test_differentSourcesAreIsolated() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        store.store([face(cx: 0.2)], sourceID: sourceB, time: 1.0)

        XCTAssertEqual(store.count, 2)
        XCTAssertNil(store.faces(sourceID: UUID(), time: 1.0))
    }

    /// 「検出したが顔がなかった」を空配列で記録でき、未検出と区別できること。
    /// この区別が壊れると、誤検出を空で上書きして消せなくなる。
    func test_emptyResultIsDistinctFromMissing() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([], sourceID: sourceA, time: 1.0)

        XCTAssertEqual(store.faces(sourceID: sourceA, time: 1.0)?.isEmpty, true)
        XCTAssertTrue(store.hasEntry(sourceID: sourceA, time: 1.0))
        XCTAssertFalse(store.hasEntry(sourceID: sourceA, time: 5.0))
        XCTAssertNil(store.faces(sourceID: sourceA, time: 5.0))
    }

    /// 近傍検索は window 秒以内の最も近い非空エントリを返すこと。
    func test_nearestFacesWithinWindow() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)

        XCTAssertEqual(store.nearestFaces(sourceID: sourceA, time: 1.2, window: 0.5).count, 1)
        XCTAssertTrue(store.nearestFaces(sourceID: sourceA, time: 3.0, window: 0.5).isEmpty)
    }

    /// 近傍検索は他の素材のエントリを拾わないこと。
    func test_nearestFacesDoesNotCrossSources() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        XCTAssertTrue(store.nearestFaces(sourceID: sourceB, time: 1.0, window: 0.5).isEmpty)
    }

    /// 素材単位で破棄できること（素材を差し替えたときに使う）。
    func test_removeBySource() {
        let store = DetectionCacheStore(bucketFPS: 15)
        store.store([face(cx: 0.5)], sourceID: sourceA, time: 1.0)
        store.store([face(cx: 0.2)], sourceID: sourceB, time: 1.0)

        store.removeAll(sourceID: sourceA)

        XCTAssertNil(store.faces(sourceID: sourceA, time: 1.0))
        XCTAssertNotNil(store.faces(sourceID: sourceB, time: 1.0))
    }

    /// 本設計の核心の回帰テスト。
    /// クリップを削除して後続クリップの合成時刻がずれても、
    /// 素材基準のキャッシュは引き続き同じ検出結果を返すこと。
    func test_detectionSurvivesClipRemoval() {
        let store = DetectionCacheStore(bucketFPS: 15)
        let clipA = TimelineClip(sourceID: sourceA, sourceStart: 0, sourceEnd: 3)
        let clipB = TimelineClip(sourceID: sourceB, sourceStart: 10, sourceEnd: 14)

        // 素材Bの11秒地点に顔を検出済み
        store.store([face(cx: 0.7)], sourceID: sourceB, time: 11.0)

        // 削除前: 合成時刻 4.0 が素材Bの 11.0 に対応
        let before = TimelineMapping(clips: [clipA, clipB])
        let locBefore = before.sourceLocation(at: 4.0)
        XCTAssertEqual(locBefore?.sourceID, sourceB)
        XCTAssertEqual(store.faces(sourceID: locBefore!.sourceID, time: locBefore!.time)?.count, 1)

        // クリップAを削除 → 同じ映像が合成時刻 1.0 に移動
        let after = TimelineMapping(clips: [clipB])
        let locAfter = after.sourceLocation(at: 1.0)
        XCTAssertEqual(locAfter?.sourceID, sourceB)
        XCTAssertEqual(locAfter?.time ?? 0, 11.0, accuracy: 1e-9)

        // 検出結果は失われていない
        XCTAssertEqual(store.faces(sourceID: locAfter!.sourceID, time: locAfter!.time)?.count, 1)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && swift test --filter DetectionCacheStoreTests 2>&1 | tail -20
```

Expected: FAIL。`cannot find 'DetectionCacheStore' in scope`

- [ ] **Step 3: DetectionCacheStore を実装する**

`Sources/MosaicCore/Timeline/DetectionCacheStore.swift`:

```swift
import Foundation

/// 検出結果を素材基準のキーで保持する。
///
/// 「エントリが無い（未検出）」と「エントリはあるが空（検出したが顔なし）」を
/// 区別する。この区別が壊れると、誤検出を空で上書きして消せなくなる。
public final class DetectionCacheStore {
    private var storage: [DetectionCacheKey: [FaceLandmarkSet]] = [:]
    private let bucketFPS: Double

    public init(bucketFPS: Double = 15.0) {
        self.bucketFPS = bucketFPS
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var allEntries: [DetectionCacheKey: [FaceLandmarkSet]] { storage }

    private func key(_ sourceID: UUID, _ time: Double) -> DetectionCacheKey {
        DetectionCacheKey(sourceID: sourceID, time: time, bucketFPS: bucketFPS)
    }

    public func store(_ faces: [FaceLandmarkSet], sourceID: UUID, time: Double) {
        storage[key(sourceID, time)] = faces
    }

    /// 完全一致（同一バケット）の検出結果。エントリが無ければ nil。
    public func faces(sourceID: UUID, time: Double) -> [FaceLandmarkSet]? {
        storage[key(sourceID, time)]
    }

    /// そのバケットが検出済みかどうか（空結果を含む）。
    public func hasEntry(sourceID: UUID, time: Double) -> Bool {
        storage[key(sourceID, time)] != nil
    }

    /// `window` 秒以内で最も近い非空エントリ。無ければ空配列。
    public func nearestFaces(sourceID: UUID, time: Double, window: Double) -> [FaceLandmarkSet] {
        var best: [FaceLandmarkSet] = []
        var bestDistance = Double.greatestFiniteMagnitude
        for (k, faces) in storage where k.sourceID == sourceID && !faces.isEmpty {
            let d = abs(k.bucket - time)
            if d <= window && d < bestDistance {
                bestDistance = d
                best = faces
            }
        }
        return best
    }

    public func removeAll() {
        storage.removeAll()
    }

    public func removeAll(sourceID: UUID) {
        storage = storage.filter { $0.key.sourceID != sourceID }
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && swift test --filter DetectionCacheStoreTests 2>&1 | tail -20
```

Expected: PASS。**実行されたテスト数が 8 であることを確認する**

- [ ] **Step 5: コミット**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && git add Sources/MosaicCore/Timeline/DetectionCacheStore.swift Tests/MosaicCoreTests/DetectionCacheStoreTests.swift && git commit -m "feat: 素材基準の検出キャッシュ保管庫を追加

クリップ削除後も検出結果が失われないことを回帰テストで固定した。
未検出と「検出したが顔なし」の区別も維持する。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Composition ビルダー

**Files:**
- Create: `MaskMe/Model/TimelineCompositionBuilder.swift`
- Create: `MaskMeTests/TimelineCompositionBuilderTests.swift`

**Interfaces:**
- Consumes: `TimelineClip`（Task 1）
- Produces: `TimelineCompositionBuilder`（`init()`, `build(clips:sources:) async throws -> AVMutableComposition`）、`TimelineCompositionBuilder.BuildError`（`.missingSource(UUID)`, `.noVideoTrack`）

**注意:** 新規ファイルのため、実装後に `xcodegen generate` と `pod install` が必要。

- [ ] **Step 1: 失敗するテストを書く**

`MaskMeTests/TimelineCompositionBuilderTests.swift`:

```swift
import XCTest
import AVFoundation
import MosaicCore
@testable import MaskMe

/// Composition 構築のテスト。実素材を使わず、生成した無音・単色動画で検証する。
final class TimelineCompositionBuilderTests: XCTestCase {
    /// テスト用に指定秒数の単色動画を生成する。
    /// 外部の素材ファイルに依存しないための自前生成。
    private func makeTestVideo(seconds: Double) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 240
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        let total = Int(seconds * Double(fps))
        for i in 0..<total {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 240,
                                kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0x40,
                   CVPixelBufferGetBytesPerRow(buffer) * 240)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer,
                           withPresentationTime: CMTime(value: CMTimeValue(i),
                                                        timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// 単一クリップでも Composition を経由すること。
    /// 特別扱いの分岐を作らない設計を固定する。
    func test_singleClipProducesComposition() async throws {
        let url = try await makeTestVideo(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let clip = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 2)
        let builder = TimelineCompositionBuilder()
        let composition = try await builder.build(
            clips: [clip], sources: [sourceID: AVURLAsset(url: url)])

        let duration = try await composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.15)
        let tracks = try await composition.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    /// 2クリップを連結すると尺が合算されること。
    func test_twoClipsAreConcatenated() async throws {
        let url = try await makeTestVideo(seconds: 3.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceID = UUID()
        let sources = [sourceID: AVURLAsset(url: url) as AVAsset]
        let first = TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: 1)
        let second = TimelineClip(sourceID: sourceID, sourceStart: 2, sourceEnd: 3)

        let composition = try await TimelineCompositionBuilder()
            .build(clips: [first, second], sources: sources)

        let duration = try await composition.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2.0, accuracy: 0.15)
    }

    /// 素材が見つからない場合はエラーを投げること（黙って短い動画を作らない）。
    func test_missingSourceThrows() async throws {
        let clip = TimelineClip(sourceID: UUID(), sourceStart: 0, sourceEnd: 1)
        do {
            _ = try await TimelineCompositionBuilder().build(clips: [clip], sources: [:])
            XCTFail("素材欠落を検出できていない")
        } catch TimelineCompositionBuilder.BuildError.missingSource {
            // 期待どおり
        }
    }
}
```

- [ ] **Step 2: TimelineCompositionBuilder を実装する**

`MaskMe/Model/TimelineCompositionBuilder.swift`:

```swift
import AVFoundation
import Foundation
import MosaicCore

/// クリップ列から `AVMutableComposition` を構築する。
///
/// `AVMutableComposition` は `AVAsset` のサブクラスなので、
/// プレビューの `AVPlayerItem` も書き出しの `AVAssetReader` も
/// 合成結果をそのまま1本の動画として扱える。
///
/// 単一クリップの場合も必ず Composition を経由させる。
/// 「1本のときは素の AVAsset を使う」という分岐を作ると、
/// 単一と複数で挙動が分かれて必ず腐るため。
struct TimelineCompositionBuilder {
    enum BuildError: Error {
        /// クリップが参照する素材が `sources` に無い。
        case missingSource(UUID)
        case noVideoTrack
    }

    /// - Parameters:
    ///   - clips: 並び順どおりに連結される。
    ///   - sources: 素材IDから AVAsset への対応表。
    func build(clips: [TimelineClip], sources: [UUID: AVAsset]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BuildError.noVideoTrack
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        for clip in clips {
            guard let asset = sources[clip.sourceID] else {
                throw BuildError.missingSource(clip.sourceID)
            }
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw BuildError.noVideoTrack
            }

            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600))

            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)

            // 先頭クリップの向きを出力の基準にする。
            if cursor == .zero {
                videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
            }

            // 音声は無い素材もあるため、あるときだけ差し込む。
            if let audioTrack,
               let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }

            cursor = cursor + range.duration
        }
        return composition
    }
}
```

- [ ] **Step 3: プロジェクトファイルを再生成する**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && xcodegen generate && LANG=en_US.UTF-8 pod install
```

Expected: `Pod installation complete!` で終わること

- [ ] **Step 4: テストが通ることを確認**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && xcodebuild test -workspace MaskMe.xcworkspace -scheme MaskMe -destination 'platform=iOS Simulator,id=B418FA35-66F1-46C7-A314-EA162FC3D6CD' -only-testing:MaskMeTests/TimelineCompositionBuilderTests 2>&1 | grep -E "Test Case|Executed|TEST"
```

Expected: 3件すべて passed。**`Test Case ... passed` の行が3行あることを目視する**（0件で SUCCEEDED になる事故があるため）

- [ ] **Step 5: コミット**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && git add MaskMe/Model/TimelineCompositionBuilder.swift MaskMeTests/TimelineCompositionBuilderTests.swift project.yml MaskMe.xcodeproj Podfile.lock && git commit -m "feat: クリップ列から AVMutableComposition を構築する

単一クリップでも必ず Composition を経由させる。単一と複数で
分岐を作ると挙動が分かれて腐るため。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## 計画改訂の記録（2026-07-19）

当初の Task 5 は着手前に停止した。理由は 2 つ。

1. 合格条件「`DetectionCacheSyncTests` 9 件」が事実誤認だった。実際は **4 件**である。
2. その 4 件の `makeModel()` は `load(videoURL:)` を呼ばない。当初計画ではクリップは
   `load(videoURL:)` の中でしか作られないため、テストでは `clips == []` となり
   `sourceLocation(at:)` が常に nil を返す。「nil なら何もしない」規則に従うと
   キャッシュ書き込みが全て no-op になり、4 件中 3 件が落ちる。

より根本的な問題として、当初の Task 5 は**3 つの異なる変更を 1 タスクに詰め込んでいた**。

- (a) 検出キャッシュのキーを素材基準にする
- (b) プレビュー・書き出しを Composition 経由にする
- (c) 合成時刻 ⇄ 素材時刻の変換層を検出経路に配線する

このうち **(c) はフェーズ1では恒等変換にしかならない**。素材全体を使う単一クリップしか
存在しないため、`sourceLocation(at:)` は入力をそのまま返すだけである。にもかかわらず
(c) は、アプリで最も品質を作り込んできた検出・追跡経路を差し替える。**得るものがゼロで、
回帰リスクだけが最大**という割の合わない変更だった。

設計書がキー再設計を求めた理由は「クリップ編集をしても検出結果が失われないこと」であり、
それは **(a) のキー変更だけで達成される**。(c) が意味を持つのはクリップが複数になる
フェーズ2以降である。

したがって以下のとおり改訂する。

- **(c) はフェーズ1の対象外とする。** `TimelineMapping` は Task 2 で実装・テスト済みだが、
  検出経路への配線はフェーズ2でカット編集 UI を入れるときに行う。
- (a) を Task 5、(b) を Task 6 に分離する。それぞれ独立した合格条件を持つ。
- `liveFlowCache` はフェーズ1では合成時刻キーのまま**触らない**。素材基準へ寄せるのは
  フェーズ2で `TimelineMapping` を配線するときに `detectionCache` と対称に行う。

### 調査で確定した事実（改訂前タスクの調査による）

- `MosaicEditorModel` はクラス全体が `@MainActor`。ライブ検出はバックグラウンドキューで
  検出のみ行い、結果の格納は `Task { @MainActor in }` 経由で戻る。よって `cacheStore` を
  非 static stored property として持てば、`DetectionCacheStore` が `Sendable` でも
  同期機構付きでもなくても現状と同じ安全性が保てる。
- `.swiftlint.yml` の `file_length` は warning 500 / **error 800**。
  `MosaicEditorModel.swift` は現在 **1229 行**で既に error 閾値を超えている。
  着手前から lint が通っていない可能性が高いため、**まず現状の lint 結果を記録**すること。
- `TimelineMapping.compositionTime(clipID:sourceTime:)` は上限が閉区間で
  `sourceLocation(at:)` の半開区間と非対称である。フェーズ1では使わないため保留し、
  フェーズ2で配線する前に決着させる。
- `detectionCache` の実測参照行（当初計画の行番号は全てズレている。現ファイル 1229 行）:
  88 定義 / 230 シード / 528 DetectionBridge / 559・571・589 近傍探索 /
  661 `storePreScanResult` / 667 `recordScannedEmptyForTesting` / 686 未検出判定 /
  727・774 ライブ格納 / 939 診断ログ / 1107 エクスポート受け渡し。
  **着手時に必ず再確認すること。**

---

### Task 5: 検出キャッシュを素材基準のキーに載せ替える

**Files:**
- Modify: `MaskMe/Model/MosaicEditorModel.swift`
- Modify: `MaskMeTests/DetectionCacheSyncTests.swift`（**1 行のみ**。下記 Step 5 参照）
- Modify: `MaskMe/Export/VideoMosaicExporter.swift`（呼び出し側の型合わせのみ。シグネチャは変えない）

**このタスクでやらないこと（重要）:**
- `TimelineMapping` を使わないこと。`sourceLocation(at:)` を呼ばないこと
- `AVMutableComposition` を作らないこと。プレビュー経路に触らないこと
- `liveFlowCache` / `livePropagatedFaces` に触らないこと
- `VideoMosaicExporter.export` のシグネチャを変えないこと

**このタスクの合格条件:** 既存の `DetectionCacheSyncTests` **4 件**が通ること。
アサーションを 1 つも変えないこと。変更してよいのは Step 5 の 1 行だけ。

**設計の要点: モデルは常に素材 ID を持つ**

`MosaicEditorModel` は「1 本の素材を編集する画面」を表す。素材の**同一性**は、
その素材を「どの範囲使うか」（= クリップ）とは独立に存在する。したがって
`currentSourceID` は `init` で確定させ、クリップの有無に依存させない。

これはクリップモデルと矛盾しない。クリップは「使う範囲」であって「素材の同一性」ではない。
この分離により、動画ロード前でもキャッシュ操作が成立し、既存テストの前提が保たれる。

- [ ] **Step 1: 現状のベースラインを記録する**

```bash
swiftlint lint --quiet 2>&1 | tail -20
```

lint の**現状の違反**をレポートに記録すること。このタスクで違反を増やさないことが基準であり、
着手前から出ている違反をこのタスクで解消する義務はない。

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && xcodebuild test -workspace MaskMe.xcworkspace -scheme MaskMe -destination 'platform=iOS Simulator,id=B418FA35-66F1-46C7-A314-EA162FC3D6CD' -only-testing:MaskMeTests/DetectionCacheSyncTests 2>&1 | grep -E "Test Case|Executed"
```

Expected: **4 件 passed**。この 4 件が載せ替え後も通ることが合格条件。

- [ ] **Step 2: モデルに素材 ID とキャッシュ保管庫を追加する**

`MosaicEditorModel` の `detectionCache` 定義（実測 88 行目付近）を置き換える。

```swift
    /// この編集画面が扱う素材の識別子。クリップの有無とは独立に存在する。
    ///
    /// 素材の「同一性」は、その素材をどの範囲使うか（= クリップ）とは別の概念である。
    /// 動画ロード前でもキャッシュ操作が成立するよう、init で確定させる。
    let currentSourceID = UUID()
    /// 素材基準の検出キャッシュ。クラス全体が @MainActor なので同期機構は不要。
    let cacheStore = DetectionCacheStore(bucketFPS: 15.0)
```

`detectionCache` プロパティは**削除する**。互換用の computed property は残さないこと
（残すと 2 系統の読み方が並存して必ず腐る）。

- [ ] **Step 3: 全参照箇所を `cacheStore` 経由に置き換える**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && grep -n "detectionCache" MaskMe/ -r
```

で現在の全参照を洗い出し、1 箇所ずつ置き換える。対応は次のとおり。

| 旧 | 新 |
|---|---|
| `detectionCache[bucket] = faces` | `cacheStore.store(faces, sourceID: currentSourceID, time: t)` |
| `detectionCache[bucket]` （読み） | `cacheStore.faces(sourceID: currentSourceID, time: t)` |
| `detectionCache[bucket] != nil` | `cacheStore.hasEntry(sourceID: currentSourceID, time: t)` |
| `detectionCache.count` | `cacheStore.count` |
| 近傍走査の手書きループ | `cacheStore.nearestFaces(sourceID:time:window:)` |

**注意点:**

- **丸めは `DetectionCacheStore` が内部で行う。** 呼び出し側で `liveBucket(_:)` に
  通してから渡しても、生の時刻を渡しても同じキーになる。既存の `liveBucket` 呼び出しは
  そのまま残してよい（挙動は変わらない）が、二重に丸める必要はない。
  `DetectionCacheKey` の**生 init `init(sourceID:bucket:)` は使わないこと**。
- **「エントリが無い」と「エントリはあるが空」の区別を絶対に壊さないこと。**
  `faces()` は前者で `nil`、後者で `[]` を返す。`?? []` で潰すと
  `test_preScanEmptyResultClearsLiveFalsePositive` と
  `test_blinkDropoutIsBridgedOnFirstPlaythrough` が意味を失う。
- 近傍走査を `nearestFaces` に置き換える際、**既存の時間窓の値を変えないこと**
  （±0.1s / 0.75s / まばたき保持 0.25s）。既存ループが「非空の最近傍」以外の
  条件を持っているなら、`nearestFaces` に置き換えず既存ロジックのまま
  `cacheStore.allEntries` を走査してよい。**振る舞いの同一性が最優先**である。

- [ ] **Step 4: `DetectionBridge` への受け渡しを合わせる**

`DetectionBridge` は `[Double: [FaceLandmarkSet]]` を受け取る（実測 528 行目付近）。
現在の素材のエントリを抜き出して従来の形に組み直す。

```swift
        var sourceScoped: [Double: [FaceLandmarkSet]] = [:]
        for (key, faces) in cacheStore.allEntries where key.sourceID == currentSourceID {
            sourceScoped[key.bucket] = faces
        }
```

フェーズ1では素材が 1 つしかないため、この抜き出しは全件コピーになる。
毎フレーム呼ばれる経路であれば**コストが問題にならないか確認し、問題があれば
レポートに書くこと**（当初計画はここを検討していない）。

- [ ] **Step 5: テストの 1 行だけを直す**

`MaskMeTests/DetectionCacheSyncTests.swift:46` の

```swift
        XCTAssertEqual(model.detectionCache.count, 1,
```

を

```swift
        XCTAssertEqual(model.cacheStore.count, 1,
```

に変える。**変更はこの 1 行のみ。** アサーションの意味・メッセージ・他の 3 件は
一切触らないこと。他のテストを直したくなったら、それは実装側が間違っている合図である。

- [ ] **Step 6: エクスポートへの受け渡しを合わせる**

実測 1107 行目付近、`VideoMosaicExporter.export` に `detectionCache` を渡している箇所を、
Step 4 と同じ方法で `[Double: [FaceLandmarkSet]]` に射影して渡す。
**`export` のシグネチャは変更しない。**

- [ ] **Step 7: テストを実行する**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && xcodebuild clean -workspace MaskMe.xcworkspace -scheme MaskMe > /dev/null 2>&1 && xcodebuild test -workspace MaskMe.xcworkspace -scheme MaskMe -destination 'platform=iOS Simulator,id=B418FA35-66F1-46C7-A314-EA162FC3D6CD' -skip-testing:MaskMeTests/SampleFalsePositiveTests -skip-testing:MaskMeTests/DiagLivePathDumpTests -skip-testing:MaskMeTests/DValidLiveModelTests 2>&1 | grep -E "Test Case.*(passed|failed)|Executed|TEST"
```

Expected: `DetectionCacheSyncTests` の **4 件が passed** の行が見えること。総件数も記録すること。
`clean` を挟むのは、ビルドキャッシュが古いまま「新規テストが走らずに成功表示が出る」事故を防ぐため。

- [ ] **Step 8: lint が Step 1 から悪化していないことを確認しコミット**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && swiftlint lint --quiet 2>&1 | tail -20
```

Step 1 で記録した違反から**増えていない**こと。増えていたら
`MosaicEditorModel+Timeline.swift` に extension として切り出す。

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && git add -A && git commit -m "refactor: 検出キャッシュを素材基準のキーに載せ替え

キーを合成時刻から (素材ID, 素材内時刻) に変更した。クリップの分割・削除・
並べ替えをしても検出結果が失われないようにするため。素材IDはクリップの有無とは
独立にモデルが保持する。

変換層 (TimelineMapping) の配線はフェーズ1では行わない。単一クリップでは
恒等変換にしかならず、品質を作り込んできた検出経路を差し替える見返りがないため。
配線はクリップが複数になるフェーズ2で行う。

既存の DetectionCacheSyncTests 4件が引き続き通ることを合格条件とした。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: プレビューと書き出しを Composition 経由にする

**Files:**
- Modify: `MaskMe/Model/MosaicEditorModel.swift`（動画ロード箇所）
- Modify: `MaskMe/Model/MosaicPreviewController.swift`（`init` と `setupPlayer`）

**このタスクでやらないこと:**
- 検出キャッシュに触らないこと（Task 5 で完了している）
- `TimelineMapping` を使わないこと

**このタスクの合格条件:** 実機・シミュレータで、プレビュー再生・シーク・書き出しが
**フェーズ1着手前と見分けがつかないこと**。

- [ ] **Step 1: 動画ロード時にクリップと Composition を作る**

`load(videoURL:)` の中の `videoDuration` を読み込んでいる `Task` を次のようにする。
**クリップ構築と Composition 構築は 1 つの `Task` にまとめること**（別々にすると順序が競合する）。

```swift
        Task {
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            videoDuration = seconds

            // フェーズ1では素材全体を使う単一クリップ。
            sources = [currentSourceID: asset]
            clips = [TimelineClip(sourceID: currentSourceID,
                                  sourceStart: 0, sourceEnd: seconds)]

            guard let r = renderer else { return }
            do {
                let composition = try await TimelineCompositionBuilder()
                    .build(clips: clips, sources: sources)
                previewController = MosaicPreviewController(
                    renderer: r, asset: composition, model: self)
            } catch {
                errorMessage = "動画の読み込みに失敗しました"
            }
        }
```

対応するプロパティを追加する。

```swift
    /// タイムライン上のクリップ列。フェーズ1では常に1要素。
    @Published private(set) var clips: [TimelineClip] = []
    /// 素材IDから AVAsset への対応表。
    private var sources: [UUID: AVAsset] = [:]
```

**注意:** 既存の `previewController` 生成箇所（実測 252 行目付近）は削除すること。
2 箇所で生成すると二重に作られる。

- [ ] **Step 2: PreviewController を AVAsset 受け取りに変更する**

`MaskMe/Model/MosaicPreviewController.swift` の init を変更する。

```swift
    /// - Parameter asset: 合成済みの `AVMutableComposition` を受け取る。
    ///   URL ではなく AVAsset を受けることで、クリップ編集の結果を
    ///   そのまま再生できる。
    init(renderer: MosaicRenderer, asset: AVAsset, model: MosaicEditorModel) {
```

`setupPlayer(_ url: URL)` を `setupPlayer(_ asset: AVAsset)` に変更し、
`AVPlayerItem(url:)` を `AVPlayerItem(asset:)` に置き換える。
`private var videoURL: URL?` は使われなくなるため削除する。

**呼び出し側が他にもないか `grep -n "MosaicPreviewController(" MaskMe/ -r` で確認すること。**

- [ ] **Step 3: 書き出しにも Composition を渡す**

エクスポートに渡す `asset` を、素の `videoAsset` ではなく Composition に変更する。
Composition を毎回作り直すのではなく、Step 1 で作ったものを保持して使い回すこと。

- [ ] **Step 4: テストを実行する**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && xcodebuild clean -workspace MaskMe.xcworkspace -scheme MaskMe > /dev/null 2>&1 && xcodebuild test -workspace MaskMe.xcworkspace -scheme MaskMe -destination 'platform=iOS Simulator,id=B418FA35-66F1-46C7-A314-EA162FC3D6CD' -skip-testing:MaskMeTests/SampleFalsePositiveTests -skip-testing:MaskMeTests/DiagLivePathDumpTests -skip-testing:MaskMeTests/DValidLiveModelTests 2>&1 | grep -E "Test Case.*(passed|failed)|Executed|TEST"
```

Expected: 全て passed。Task 5 と同じ総件数であること。

- [ ] **Step 5: lint を確認しコミット**

---

### Task 7: 実機確認とレビュー

**Files:** なし（検証のみ）

- [ ] **Step 1: シミュレータで動作確認**

1. 動画を読み込む → プレビューが表示される
2. 再生する → モザイクが顔に追従する
3. シークする → モザイク位置が正しい
4. 顔サムネをタップして選択を切り替える → 反映される
5. 書き出す → 完了し、Photos に保存される

**フェーズ1の合格条件は「フェーズ1着手前と見分けがつかないこと」**である。
何か挙動が変わっていたら、それは回帰である。

- [ ] **Step 2: サブエージェントによる厳格レビュー**

ブランチ全体の差分をレビューさせる。レビュー観点として次を明示的に伝えること。

- 検出キャッシュの読み書きで、素材 ID を取り違えている箇所はないか
- 「エントリが無い」と「エントリはあるが空」の区別が失われていないか
- `liveFlowCache` と `livePropagatedFaces` の時間窓が維持されているか
- 単一クリップを特別扱いする分岐が紛れ込んでいないか
- `previewController` が二重に生成されていないか
- 各タスクのレビューで積み残した Minor 指摘（進捗台帳 `.superpowers/sdd/progress.md`
  に一覧がある）のうち、マージ前に直すべきものはどれか

- [ ] **Step 3: PR を作成**

`main` へ直接 push しないこと。PR 経由でマージすること。

---

## フェーズ2に持ち越す論点

改訂の過程で判明し、フェーズ1では決着させないと決めた事項。

| 論点 | 内容 |
|---|---|
| `TimelineMapping` の配線 | 検出経路への配線はフェーズ2で行う。単一クリップでは恒等変換のため |
| 境界の非対称 | `sourceLocation` は半開区間、`compositionTime` は閉区間。往復変換が境界で非対称。カット UI が `compositionTime` を使い始める前に決着させる |
| `liveFlowCache` の基準 | フェーズ1では合成時刻キーのまま。`detectionCache` と対称に素材基準へ寄せる |
| `DetectionCacheKey` の生 init | 丸めを通さない `init(sourceID:bucket:)` が残っている。丸め忘れ回帰の再発経路。使用箇所ゼロを維持できるか、削除するか |
| `nearestFaces` の計算量 | 毎回全走査 O(n)。長尺・複数素材で重くなる |
