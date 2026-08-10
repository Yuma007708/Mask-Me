import CoreGraphics
import XCTest
@testable import MosaicCore

/// `ObjectMask` の不変条件を固定する。
///
/// 守っているのは **「どの時刻でも矩形が 1 つに決まること」**。
/// 非空・昇順・同時刻の重複なしが崩れると補間が別の区間を引き、
/// モザイクが画面の別の場所に出る（プライバシー上の実害）。
final class ObjectMaskTests: XCTestCase {
    private let unit = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)

    private func rect(x: CGFloat) -> CGRect {
        CGRect(x: x, y: 0, width: 0.1, height: 0.1)
    }

    /// 時間軸を持つアンカー。`.still` は「時刻 0 のキーフレーム 1 個」へ畳まれるので、
    /// 補間やキーフレーム編集を検証するテストは必ずこちらを使う。
    private let clipAnchor = ObjectMask.Anchor.clip(clipID: UUID(), sourceID: UUID())

    // MARK: - 不変条件（非空）

    /// **同じ id のキーフレームが 2 個あっても、削除でマスクが空になってはいけない。**
    ///
    /// 設計レビューで見つかった実クラッシュの回帰テスト。`normalized` が時刻でしか
    /// 重複を潰さないため id 重複は素通りし、`removingKeyframe` の `filter` が
    /// **両方**を落として空の `ObjectMask` を非 nil で返していた。
    /// その後 `rect(atSourceTime:)` の `keyframes[0]` で Index out of range になる。
    func test_id重複のキーフレームを削除してもマスクが空にならない() {
        let shared = UUID()
        let mask = ObjectMask(
            id: UUID(), anchor: clipAnchor,
            keyframes: [ObjectMask.Keyframe(id: shared, sourceTime: 0, rect: rect(x: 0)),
                        ObjectMask.Keyframe(id: shared, sourceTime: 1, rect: rect(x: 0.5))])
        // そもそも id 重複を作らせない（正規化で一意化する）のが本筋。
        XCTAssertEqual(mask?.keyframes.count, 1, "id 重複が正規化で潰されていない")

        // 潰した上でなお、最後の 1 個は消せない（nil = マスクごと消せの合図）。
        if let mask, let only = mask.keyframes.first {
            XCTAssertNil(mask.removingKeyframe(id: only.id))
        }
    }

    /// 削除の結果が空になる入力では必ず nil を返し、空のマスクを作らせない。
    func test_最後のキーフレームは消せずnilを返す() {
        let mask = ObjectMask.single(anchor: clipAnchor, rect: unit)
        XCTAssertNotNil(mask)
        guard let mask, let only = mask.keyframes.first else { return XCTFail("生成に失敗") }
        XCTAssertNil(mask.removingKeyframe(id: only.id))
    }

    // MARK: - 補間の端（clamp）

    /// `+Inf` は「最後より後」なので**最後の矩形**を返す。
    ///
    /// `isFinite` の早期 return が `+Inf` も捕まえて最初の矩形を返していた。
    /// このプロジェクトには「+∞ の sourceEnd が写像全体を汚染した」実測が
    /// `TimelineEditOperations` の doc に残っており、非有限の時刻は実際に到達する。
    func test_正の無限大は最後の矩形になる() {
        let mask = ObjectMask(id: UUID(), anchor: clipAnchor,
                              keyframes: [ObjectMask.Keyframe(sourceTime: 0, rect: rect(x: 0)),
                                          ObjectMask.Keyframe(sourceTime: 5, rect: rect(x: 0.9))])
        XCTAssertEqual(mask?.rect(atSourceTime: .infinity).origin.x, 0.9)
    }

    /// `-Inf` と NaN は「最初より前」または判定不能なので最初の矩形へ倒す。
    func test_負の無限大とNaNは最初の矩形になる() {
        let mask = ObjectMask(id: UUID(), anchor: clipAnchor,
                              keyframes: [ObjectMask.Keyframe(sourceTime: 0, rect: rect(x: 0)),
                                          ObjectMask.Keyframe(sourceTime: 5, rect: rect(x: 0.9))])
        XCTAssertEqual(mask?.rect(atSourceTime: -.infinity).origin.x, 0)
        XCTAssertEqual(mask?.rect(atSourceTime: .nan).origin.x, 0)
    }

    /// キーフレーム 1 個なら全時刻で同じ矩形（旧 `ManualRegion` 互換）。
    func test_キーフレーム1個は全時刻で同じ矩形になる() {
        let mask = ObjectMask.single(anchor: clipAnchor, rect: unit)
        for time in [-100.0, 0, 0.5, 1e6] {
            XCTAssertEqual(mask?.rect(atSourceTime: time), unit)
        }
    }

    /// **矩形**が極端でも補間結果は有限。成分ごとに有限でも差分が overflow するため、
    /// 出力側でも検査しないと NaN/Inf の矩形が描画・エクスポートへ流れる。
    func test_矩形が極端でも補間結果は有限になる() {
        let mask = ObjectMask(
            id: UUID(), anchor: clipAnchor,
            keyframes: [ObjectMask.Keyframe(sourceTime: 0, rect: rect(x: -1e308)),
                        ObjectMask.Keyframe(sourceTime: 1, rect: rect(x: 1e308))])
        let result = mask?.rect(atSourceTime: 0.5)
        XCTAssertNotNil(result)
        XCTAssertTrue(ObjectMask.isFinite(result ?? .null),
                      "補間が非有限の矩形を返した: \(String(describing: result))")
    }

    /// **時刻**が極端なキーフレームは正規化の量子化段階で捨てる
    /// （丸めで overflow するため、そもそも扱える時刻ではない）。
    func test_時刻が極端なキーフレームは正規化で捨てられる() {
        let mask = ObjectMask(
            id: UUID(), anchor: clipAnchor,
            keyframes: [ObjectMask.Keyframe(sourceTime: -1.5e308, rect: rect(x: 0)),
                        ObjectMask.Keyframe(sourceTime: 1, rect: rect(x: 0.5))])
        XCTAssertEqual(mask?.keyframes.count, 1)
        XCTAssertEqual(mask?.keyframes.first?.sourceTime, 1)
    }

    // MARK: - 時刻の量子化

    /// 素材時刻は毎回計算される Double なので 1 ulp 単位で揺れる。厳密比較のままだと
    /// 「同じ位置で置き直したのに新しいキーフレームが増える」粉塵になる。
    func test_1ulp違う時刻は同じキーフレームとして置換される() {
        let base = 0.3
        let jittered = base.nextUp.nextUp
        XCTAssertNotEqual(base, jittered, "前提: 2 つは厳密比較で別の値")

        let mask = ObjectMask.single(anchor: clipAnchor, sourceTime: 0, rect: rect(x: 0))?
            .settingKeyframe(atSourceTime: base, rect: rect(x: 0.4))
            .settingKeyframe(atSourceTime: jittered, rect: rect(x: 0.7))
        // 0 と 0.3 の 2 個。0.3 の矩形は後から置いた方（x=0.7）で上書きされる。
        XCTAssertEqual(mask?.keyframes.count, 2, "1 ulp 差でキーフレームが増殖した")
        XCTAssertEqual(mask?.rect(atSourceTime: base).origin.x, 0.7)
    }

    // MARK: - `.still` の不変条件（型が守る）

    /// `.still` は時間軸を持たないので、複数キーフレームを渡しても
    /// 「時刻 0 の 1 個」へ畳まれる。
    ///
    /// **この検査を `TimelineState.validate()` に委ねてはいけない。**
    /// `validate()` の呼び出しはテストにしか無く、本番では誰も落とさないため、
    /// 不変条件違反が黙って永続化される（`MosaicApplyRange` の doc が警告する罠）。
    func test_stillは時刻0のキーフレーム1個へ畳まれる() {
        let mask = ObjectMask(
            id: UUID(), anchor: .still,
            keyframes: [ObjectMask.Keyframe(sourceTime: 3, rect: rect(x: 0.2)),
                        ObjectMask.Keyframe(sourceTime: 7, rect: rect(x: 0.8))])
        XCTAssertEqual(mask?.keyframes.count, 1)
        XCTAssertEqual(mask?.keyframes.first?.sourceTime, 0)
        // 残るのは時刻順で最初の 1 個（規則を固定しないとデコードのたびに矩形が変わる）。
        XCTAssertEqual(mask?.keyframes.first?.rect.origin.x, 0.2)
    }

    /// `.still` へのキーフレーム追加は「矩形の描き直し」として時刻 0 へ畳む
    /// （拒否ではない。静止画でも矩形を置き直す操作は通したいため）。
    func test_stillへ別時刻のキーフレームを置いても1個のまま() {
        let mask = ObjectMask.single(anchor: .still, rect: rect(x: 0.1))?
            .settingKeyframe(atSourceTime: 5, rect: rect(x: 0.6))
        XCTAssertEqual(mask?.keyframes.count, 1)
        XCTAssertEqual(mask?.keyframes.first?.sourceTime, 0)
        XCTAssertEqual(mask?.rect(atSourceTime: 5).origin.x, 0.6, "描き直しが反映されていない")
    }

    /// `.still` に時刻の移動は無い。
    func test_stillのキーフレームは移動できない() {
        let mask = ObjectMask.single(anchor: .still, rect: unit)
        guard let mask, let only = mask.keyframes.first else { return XCTFail("生成に失敗") }
        XCTAssertEqual(mask.movingKeyframe(id: only.id, toSourceTime: 9), mask)
    }

    /// `.clip` は畳まれない（時間軸を持つ）。
    func test_clipアンカーは複数キーフレームを保つ() {
        let mask = ObjectMask(
            id: UUID(), anchor: clipAnchor,
            keyframes: [ObjectMask.Keyframe(sourceTime: 3, rect: rect(x: 0.2)),
                        ObjectMask.Keyframe(sourceTime: 7, rect: rect(x: 0.8))])
        XCTAssertEqual(mask?.keyframes.count, 2)
    }
}
