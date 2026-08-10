import XCTest
@testable import MosaicCore

/// **マージで片方が黙って消えていないことの番人。**
///
/// 区間ミュート（`clipAudioMuteRanges`）とステッカー（`TextItem.role`）は
/// 別々のブランチで実装され、あとから合流した。この案件では過去に
/// **git が競合として報告しないマージ由来の欠陥が 2 件**出ている
/// （向きを戻し忘れた逆写像・向きを引き継がない複製）。どちらも
/// 「片方の機能だけを見るテスト」では緑のまま素通りした。
///
/// ここは**両方を同時に持つ状態**だけを見る。保存・復元・不変条件のどれかで
/// 片方が落とされたら、必ずここが落ちる。
final class MergedFeatureCoexistenceTests: XCTestCase {
    private let videoSource = UUID()

    /// ステッカー・テキスト・消音区間を同時に持つ状態。
    private func makeState() -> TimelineState {
        let clip = TimelineClip(sourceID: videoSource, sourceStart: 0, sourceEnd: 10)
        var state = TimelineState(
            clips: [clip],
            sources: [videoSource: TimelineSource(id: videoSource, kind: .video)])
        state = state.addingTextItem("こんにちは", atCompositionTime: 1, duration: 3)
        state = state.addingStickerItem("😀", atCompositionTime: 2, duration: 3)
        // 消音区間は**合成時刻**で受ける（素材時刻への分解は `ClipAudioMuteGate` の仕事）。
        state = state.addingClipAudioMuteRange(fromCompositionTime: 4, to: 6)
        return state
    }

    /// 前提: そもそも 3 つとも作れていること（作れていなければ以下の検証は無意味）。
    func test_前提_ステッカーとテキストと消音区間が同時に存在できる() {
        let state = makeState()
        XCTAssertEqual(state.textItems.filter { $0.role == .text }.count, 1,
                       "テキストが作られていない")
        XCTAssertEqual(state.textItems.filter { $0.role == .sticker }.count, 1,
                       "ステッカーが作られていない")
        XCTAssertEqual(state.clipAudioMuteRanges.count, 1, "消音区間が作られていない")
        XCTAssertTrue(state.validate(), "3 つを同時に持つ状態が不変条件を満たさない")
    }

    /// **保存・復元で片方が落ちないこと。**
    ///
    /// `TimelineStateCodable` の `CodingKeys` は 2 つのブランチが同じ enum へ
    /// 別々にキーを足した箇所で、マージで片方が消えても**コンパイルは通る**
    /// （decodeIfPresent の既定値に落ちるだけ）。実際に往復させて確かめる。
    func test_保存と復元で両方の機能が残る() throws {
        let state = makeState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TimelineState.self, from: data)

        XCTAssertEqual(decoded.clipAudioMuteRanges.count, 1,
                       "往復で消音区間が消えた（Codable のキーが落ちている疑い）")
        XCTAssertEqual(decoded.textItems.filter { $0.role == .sticker }.count, 1,
                       "往復でステッカーがテキストへ化けた（role が書かれていない疑い）")
        XCTAssertEqual(decoded, state, "往復で状態が変わった")

        // JSON にキーそのものが載っていることも直接見る（既定値で往復一致してしまう
        // 事故を防ぐ。`.sticker` の往復だけは既定値では成立しない）。
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["clipAudioMuteRanges"], "消音区間のキーが書かれていない")
        XCTAssertNotNil(object["textItems"], "テキストのキーが書かれていない")
    }

    /// **クリップを分割しても両方が追従すること。**
    ///
    /// 消音区間は素材時刻アンカーで分割に追従する。ステッカーは合成時刻アンカーで
    /// 追従しない（テキストと同じ規則）。**追従する側だけ・しない側だけを見ると、
    /// もう片方の付け替えが消えていても気づけない**ので、同じテストで両方見る。
    func test_分割で消音区間は追従しステッカーは動かない() throws {
        let state = makeState()
        let clipID = try XCTUnwrap(state.clips.first).id
        let stickerBefore = try XCTUnwrap(state.textItems.first { $0.role == .sticker })

        let split = state.splitting(clipID: clipID, atDisplayTime: 5)
        XCTAssertEqual(split.clips.count, 2, "テスト前提: 分割できていること")

        // 消音区間 [4, 6) は分割点 5 をまたぐので、前後どちらのクリップにも残る。
        XCTAssertFalse(split.clipAudioMuteRanges.isEmpty,
                       "分割で消音区間が丸ごと消えた（付け替えが働いていない）")
        let owners = Set(split.clipAudioMuteRanges.map(\.clipID))
        XCTAssertTrue(owners.allSatisfy { id in split.clips.contains { $0.id == id } },
                      "存在しないクリップを指す消音区間が残った（孤児）")

        let stickerAfter = try XCTUnwrap(split.textItems.first { $0.role == .sticker })
        XCTAssertEqual(stickerAfter.compositionStart, stickerBefore.compositionStart,
                       accuracy: 1e-9,
                       "分割でステッカーが動いた（テキストと同じく追従しないのが規則）")
        XCTAssertTrue(split.validate(), "分割後の状態が不変条件を満たさない")
    }
}
