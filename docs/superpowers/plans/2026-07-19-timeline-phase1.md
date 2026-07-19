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

### Task 5: MosaicEditorModel をクリップ基盤に載せ替える

**Files:**
- Modify: `MaskMe/Model/MosaicEditorModel.swift`（`detectionCache` 定義は 88 行目、動画ロードは 236-258 行目、キャッシュ参照は 596-830 行目付近）
- Modify: `MaskMe/Model/MosaicPreviewController.swift:78`（`init(renderer:url:model:)`）
- Modify: `MaskMe/Export/VideoMosaicExporter.swift:128`（`detectionCache` 引数の型）

**Interfaces:**
- Consumes: `TimelineClip`, `TimelineMapping`, `DetectionCacheStore`, `TimelineCompositionBuilder`（Task 1-4）
- Produces: `MosaicEditorModel.clips: [TimelineClip]`, `MosaicEditorModel.timelineMapping: TimelineMapping`, `MosaicEditorModel.cacheStore: DetectionCacheStore`

**この Task の要点:** 既存の時刻ベース API のシグネチャは変えない。内部で `timelineMapping` を通して素材時刻に直してからキャッシュを引くようにする。呼び出し側（View、PreviewController）の構造は変えない。

- [ ] **Step 1: 現在の挙動を固定する回帰テストを先に書く**

既存の `MaskMeTests/DetectionCacheSyncTests.swift` は `detectionCache` を直接見ている。載せ替え後も**同じ振る舞い**を保つことを保証するため、まず現状のテストが全て通ることを確認する。

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && xcodebuild test -workspace MaskMe.xcworkspace -scheme MaskMe -destination 'platform=iOS Simulator,id=B418FA35-66F1-46C7-A314-EA162FC3D6CD' -only-testing:MaskMeTests/DetectionCacheSyncTests 2>&1 | grep -E "Test Case|Executed"
```

Expected: 9件 passed。**この9件が載せ替え後も全て通ることが Task 5 の合格条件**

- [ ] **Step 2: モデルにクリップ状態を追加する**

`MaskMe/Model/MosaicEditorModel.swift` の 88 行目付近、`private(set) var detectionCache` の定義の直後に追加する。

```swift
    /// タイムライン上のクリップ列。フェーズ1では常に1要素。
    @Published public private(set) var clips: [TimelineClip] = []
    /// 素材IDから AVAsset への対応表。
    private var sources: [UUID: AVAsset] = [:]
    /// 合成時刻 ⇄ 素材時刻の変換。`clips` の変更時に作り直す。
    private(set) var timelineMapping = TimelineMapping(clips: [])
    /// 素材基準の検出キャッシュ。
    let cacheStore = DetectionCacheStore(bucketFPS: 15.0)
```

- [ ] **Step 3: 動画ロード時にクリップを作る**

`MaskMe/Model/MosaicEditorModel.swift` の 245 行目付近、`videoDuration` を読み込んでいる箇所を次のように変更する。

変更前:

```swift
        Task {
            videoDuration = (try? await asset.load(.duration))?.seconds ?? 0
        }
```

変更後:

```swift
        Task {
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            videoDuration = seconds

            // フェーズ1では素材全体を使う単一クリップ。
            let sourceID = UUID()
            sources = [sourceID: asset]
            clips = [TimelineClip(sourceID: sourceID, sourceStart: 0, sourceEnd: seconds)]
            timelineMapping = TimelineMapping(clips: clips)
        }
```

- [ ] **Step 4: キャッシュ参照を変換層経由にする**

`lookupFaces(at:)` の内部で、合成時刻を素材時刻に変換してから `cacheStore` を引くようにする。
`MosaicEditorModel.swift` に次のヘルパを追加する（`lookupFaces` の直前）。

```swift
    /// 合成時刻に対応する素材内の位置。クリップが未構築なら nil。
    ///
    /// フェーズ1では素材全体を使う単一クリップなので、実質的に恒等変換になる。
    /// それでも変換層を通すのは、フェーズ2以降で分岐を増やさないためである。
    func sourceLocation(at compositionTime: Double) -> TimelineMapping.SourceLocation? {
        timelineMapping.sourceLocation(at: compositionTime)
    }
```

そのうえで、`detectionCache` を直接読み書きしている全箇所を `cacheStore` 経由に置き換える。対象は次のとおり（行番号は変更前のもの）。

- `230` — シード検出の格納
- `528` — `DetectionBridge` への受け渡し
- `601-613` — `nearestFlowFaces` / `nearestCachedFaces`
- `703, 709` — `storePreScanResult` / `recordScannedEmptyForTesting`
- `729` — 未検出判定
- `774-775, 824` — ライブ検出結果の格納
- `989` — 診断ログ
- `1157` — エクスポートへの受け渡し

各箇所で、合成時刻を `sourceLocation(at:)` で素材時刻に変換してから `cacheStore` の対応メソッドを呼ぶ。変換が nil を返した場合（範囲外）は、従来「キャッシュに無い」と同じ扱い（空を返す／何もしない）にする。

- [ ] **Step 5: DetectionBridge への受け渡しを合わせる**

`DetectionBridge` は `[Double: [FaceLandmarkSet]]` を受け取る（`MosaicEditorModel.swift:528`）。
現在の素材の分だけを抜き出して従来の形に組み直して渡す。

`lookupFaces(at:)` の中の該当箇所を次のようにする。

```swift
        guard let loc = sourceLocation(at: time) else { return [] }
        // DetectionBridge は素材内時刻をキーとする辞書を期待する。
        // 現在の素材のエントリだけを抜き出して渡す。
        var sourceScoped: [Double: [FaceLandmarkSet]] = [:]
        for (key, faces) in cacheStore.allEntries where key.sourceID == loc.sourceID {
            sourceScoped[key.bucket] = faces
        }
        let bridged = DetectionBridge(interpolates: true).faces(in: sourceScoped, at: loc.time)
```

- [ ] **Step 6: PreviewController を AVAsset 受け取りに変更する**

`MaskMe/Model/MosaicPreviewController.swift:78` の init を変更する。

変更前:

```swift
    init(renderer: MosaicRenderer, url: URL, model: MosaicEditorModel) {
```

変更後:

```swift
    /// - Parameter asset: 合成済みの `AVMutableComposition` を受け取る。
    ///   URL ではなく AVAsset を受けることで、クリップ編集の結果を
    ///   そのまま再生できる。
    init(renderer: MosaicRenderer, asset: AVAsset, model: MosaicEditorModel) {
```

同ファイル内の `setupPlayer(_ url: URL)` を `setupPlayer(_ asset: AVAsset)` に変更し、
`AVPlayerItem(url:)` を `AVPlayerItem(asset:)` に置き換える。
`private var videoURL: URL?` は使われなくなるため削除する。

- [ ] **Step 7: モデル側の PreviewController 生成を合わせる**

`MosaicEditorModel.swift:252` 付近を次のように変更する。

変更前:

```swift
        if let r = renderer {
            previewController = MosaicPreviewController(renderer: r, url: url, model: self)
        }
```

変更後:

```swift
        if let r = renderer {
            Task {
                do {
                    let composition = try await TimelineCompositionBuilder()
                        .build(clips: clips, sources: sources)
                    previewController = MosaicPreviewController(
                        renderer: r, asset: composition, model: self)
                } catch {
                    errorMessage = "動画の読み込みに失敗しました"
                }
            }
        }
```

**注意:** Step 3 でクリップを作る `Task` と、この `Task` の順序に依存がある。
クリップ構築を先に完了させるため、Step 3 の `Task` の中で続けて Composition を
構築し、この2つを1つの `Task` にまとめること。

- [ ] **Step 8: エクスポートの受け渡しを合わせる**

`MosaicEditorModel.swift:1157` 付近、エクスポート呼び出しで `detectionCache` を渡している箇所を、
現在の素材のエントリを抜き出した `[Double: [FaceLandmarkSet]]` に変換して渡す。
`VideoMosaicExporter.export` のシグネチャは変更しない（フェーズ1では書き出し結果を変えないため）。

またエクスポートに渡す `asset` を、素の `videoAsset` ではなく Composition に変更する。

- [ ] **Step 9: 既存テストが全て通ることを確認**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && xcodebuild clean -workspace MaskMe.xcworkspace -scheme MaskMe > /dev/null 2>&1 && xcodebuild test -workspace MaskMe.xcworkspace -scheme MaskMe -destination 'platform=iOS Simulator,id=B418FA35-66F1-46C7-A314-EA162FC3D6CD' 2>&1 | grep -E "Test Case.*(passed|failed)|Executed|TEST"
```

Expected: 全テスト passed。**`DetectionCacheSyncTests` の9件が含まれていることを目視で確認する**

`clean` を挟むのは、ビルドキャッシュが古いまま「新規テストが走らずに成功表示が出る」事故を防ぐため。

- [ ] **Step 10: SwiftLint を通す**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && swiftlint lint --quiet 2>&1 | tail -20
```

Expected: 出力なし（違反ゼロ）。`file_length` 違反が出た場合は、追加したクリップ関連のコードを `MosaicEditorModel+Timeline.swift` に extension として切り出す。

- [ ] **Step 11: コミット**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && git add -A && git commit -m "refactor: 編集モデルをクリップ基盤と素材基準キャッシュに載せ替え

見た目と挙動は変えない内部移行。検出キャッシュのキーを合成時刻から
(素材ID, 素材内時刻) に変更し、プレビューは Composition 経由にした。
既存の DetectionCacheSyncTests 9件が引き続き通ることを合格条件とした。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: 実機確認とレビュー

**Files:** なし（検証のみ）

- [ ] **Step 1: シミュレータで動作確認**

アプリを起動し、次を確認する。

1. 動画を読み込む → プレビューが表示される
2. 再生する → モザイクが顔に追従する
3. シークする → モザイク位置が正しい
4. 顔サムネをタップして選択を切り替える → 反映される
5. 書き出す → 完了し、Photos に保存される

**フェーズ1の合格条件は「フェーズ1着手前と見分けがつかないこと」**である。
何か挙動が変わっていたら、それは回帰である。

- [ ] **Step 2: サブエージェントによる厳格レビュー**

`feature-dev:code-reviewer` に `main...feat/timeline-phase1` の差分をレビューさせる。
レビュー観点として次を明示的に伝えること。

- 検出キャッシュの読み書きで、合成時刻と素材時刻を取り違えている箇所はないか
- 「エントリが無い」と「エントリはあるが空」の区別が失われていないか
- 変換が nil を返す場合（範囲外）の扱いが、従来の「キャッシュに無い」と一致しているか
- 単一クリップを特別扱いする分岐が紛れ込んでいないか
- `liveFlowCache` と `livePropagatedFaces` の時間窓が維持されているか

指摘が出たら修正し、再レビューする。

- [ ] **Step 3: PR を作成**

```bash
cd /Users/tatsuki/Desktop/mirator/projects/Mask-Me && git push -u origin feat/timeline-phase1 && gh pr create --base main --title "refactor: タイムライン編集フェーズ1（クリップ基盤・素材基準キャッシュ）" --body "$(cat <<'BODY'
## 概要

`docs/superpowers/specs/2026-07-19-timeline-editing-design.md` のフェーズ1。
画面の見た目と挙動は変えず、内部基盤のみを差し替える。

## 変更点

- クリップ列 (`TimelineClip`) と合成時刻⇄素材時刻の変換層 (`TimelineMapping`) を追加
- 検出キャッシュのキーを合成時刻から `(素材ID, 素材内時刻)` に変更
- プレビューと書き出しを `AVMutableComposition` 経由に統一（単一クリップでも）

## 合格条件

フェーズ1着手前と見分けがつかないこと。既存の `DetectionCacheSyncTests` 9件が
引き続き通ることを回帰の指標とした。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

## セルフレビュー結果

**仕様カバレッジ:** 設計書のフェーズ1に挙げた3項目（クリップモデル導入・Composition 経由化・キャッシュキー再設計）は Task 1-5 で網羅した。フェーズ2以降の項目は本計画の対象外。

**型の一貫性:** `TimelineClip`（Task 1）→ `TimelineMapping`（Task 2）→ `DetectionCacheStore`（Task 3）→ `TimelineCompositionBuilder`（Task 4）→ `MosaicEditorModel`（Task 5）で、プロパティ名とシグネチャが一致していることを確認した。

**既知の判断:** `VideoMosaicExporter.export` のシグネチャは変更しない。フェーズ1では書き出し結果を変えないことを優先し、エクスポータ側の型移行はフェーズ2で `trimRange` を廃止する際にまとめて行う。
