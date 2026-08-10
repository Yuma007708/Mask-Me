import CoreGraphics
import XCTest
@testable import MosaicCore

/// 物体マスクの自動追跡（O2）の契約を固定する。
///
/// 守っているのは 4 つ:
///
/// 1. **軌跡は必ずユーザーのキーフレームを通る**（ドリフト補正）。通らないと
///    キーフレームの瞬間だけモザイクが跳ぶ。
/// 2. **見失いは外挿の上限で止まり、そこで軌跡が切れる**。無限に当てずっぽうを続けない。
/// 3. **末尾は最後の追跡位置で止まる**（キーフレームへ逆戻りしない）。
///    これが「見失ったら最後の位置に残す」というユーザー決定の実体。
/// 4. **キーフレームを 1 個でも動かした軌跡は使われない**。古い軌跡が残ると
///    ユーザーの手直しが画面に反映されない。
final class ObjectTrackBuilderTests: XCTestCase {
    private let clipID = UUID()
    private let sourceID = UUID()
    private let imageSize = CGSize(width: 1000, height: 1000)

    private func box(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 0.1, width: 0.2, height: 0.2) }

    private func mask(_ frames: [(Double, CGFloat)]) -> ObjectMask {
        ObjectMask(anchor: .clip(clipID: clipID, sourceID: sourceID),
                   keyframes: frames.map { ObjectMask.Keyframe(sourceTime: $0.0, rect: box($0.1)) })!
    }

    /// 正規化 dx の並進変換（画像 1000px 基準）。
    private func shift(_ dx: CGFloat) -> SimilarityTransform {
        SimilarityTransform(scale: 1, rotation: 0, tx: dx * imageSize.width, ty: 0)
    }

    private func builder(_ mask: ObjectMask,
                         options: ObjectTrackBuilder.Options = .init()) -> ObjectTrackBuilder {
        ObjectTrackBuilder(mask: mask, clipID: clipID, sourceID: sourceID, options: options)!
    }

    /// 10 フレーム進めるヘルパ（0.1 秒刻み）。
    private func run(_ builder: ObjectTrackBuilder, frames: Int, dx: CGFloat, from: Int = 1) {
        for i in from...(from + frames - 1) {
            builder.advance(toSourceTime: Double(i) / 10, transform: shift(dx), imageSize: imageSize)
        }
    }

    // MARK: - ドリフト補正

    /// **追跡がずれていても、キーフレーム時刻では誤差ゼロで着地する。**
    /// 真の移動 0.4 に対しフローが 0.3 しか出さない（毎フレーム 25% 過小）状況を作る。
    func test_ドリフトはキーフレームへ誤差ゼロで着地する() {
        let target = mask([(0, 0.1), (1.0, 0.5)])
        let sut = builder(target)
        run(sut, frames: 10, dx: 0.03)
        guard let track = sut.finish() else { return XCTFail("軌跡が空") }

        XCTAssertEqual(track.rect(atSourceTime: 1.0)?.origin.x ?? .nan, 0.5, accuracy: 1e-12)
        // 誤差 0.1 が時間比例で配られる: 生 0.25 + 0.1×0.5 = 0.30（＝真値）。
        XCTAssertEqual(track.rect(atSourceTime: 0.5)?.origin.x ?? .nan, 0.30, accuracy: 1e-9)
        // 区間の入口は動かさない（前の区間との継ぎ目が割れないための不変条件）。
        XCTAssertEqual(track.rect(atSourceTime: 0)?.origin.x ?? .nan, 0.1, accuracy: 1e-12)
    }

    /// 補正しても**キーフレーム間の動きの形**は残る（ただの直線補間に潰れない）。
    /// 前半で一気に動き後半で止まる動きを入れ、中点が直線補間（0.3）とずれることを見る。
    func test_補間ではなく実際の動きの形が残る() {
        let target = mask([(0, 0.1), (1.0, 0.5)])
        let sut = builder(target)
        run(sut, frames: 5, dx: 0.08)            // 0.1 → 0.5 まで一気に
        run(sut, frames: 5, dx: 0, from: 6)      // あとは静止
        guard let track = sut.finish() else { return XCTFail("軌跡が空") }
        let mid = track.rect(atSourceTime: 0.5)?.origin.x ?? .nan
        XCTAssertEqual(mid, 0.5, accuracy: 1e-9)
        XCTAssertNotEqual(mid, target.rect(atSourceTime: 0.5).origin.x, accuracy: 0.1,
                          "直線補間と同じなら追跡が効いていない")
    }

    /// 次のキーフレームへ到達しなかった区間は補正しない（着地先が無い）。
    /// その先は**穴**になり、呼び出し側がキーフレーム補間へ落ちる。
    func test_到達しなかった区間は穴になる() {
        let target = mask([(0, 0.1), (2.0, 0.5)])
        let sut = builder(target)
        run(sut, frames: 5, dx: 0.03)                    // t=0.5 まで追跡
        for i in 6...11 {                                // 外挿上限（6）を超えて見失う
            sut.advance(toSourceTime: Double(i) / 10, transform: nil, imageSize: imageSize)
        }
        guard let track = sut.finish() else { return XCTFail("軌跡が空") }
        XCTAssertNotNil(track.rect(atSourceTime: 0.4), "追跡できた区間は返る")
        XCTAssertNil(track.rect(atSourceTime: 1.5), "追跡が切れた先は穴（キーフレーム補間へ）")
    }

    // MARK: - 見失いの扱い

    /// 短い見失いは等速外挿で埋める（1〜2 フレームのブラーで軌跡が切れない）。
    func test_短い見失いは等速で埋める() {
        let target = mask([(0, 0.1), (2.0, 0.5)])
        let sut = builder(target)
        run(sut, frames: 5, dx: 0.03)                              // 速度 0.3/秒
        sut.advance(toSourceTime: 0.6, transform: nil, imageSize: imageSize)
        guard let track = sut.finish() else { return XCTFail("軌跡が空") }
        // 0.5 の位置 0.25 から 0.1 秒ぶん（0.03）進む。
        XCTAssertEqual(track.rect(atSourceTime: 0.6)?.origin.x ?? .nan, 0.28, accuracy: 1e-9)
    }

    /// **凍結したら次のキーフレームまで追跡を再開しない。**
    /// ロックを失った位置で特徴点を取り直すと背景に貼り付くため（doc 参照）。
    func test_凍結中はフローが戻っても再開しない() {
        let target = mask([(0, 0.1), (5.0, 0.5)])
        let sut = builder(target)
        run(sut, frames: 5, dx: 0.03)
        for i in 6...13 {                                          // 外挿上限超え → 凍結
            sut.advance(toSourceTime: Double(i) / 10, transform: nil, imageSize: imageSize)
        }
        XCTAssertNil(sut.reseedRect, "凍結中は seed 先を返さない")
        for i in 14...20 {                                         // フローは戻るが無視する
            sut.advance(toSourceTime: Double(i) / 10, transform: shift(0.03), imageSize: imageSize)
        }
        guard let track = sut.finish() else { return XCTFail("軌跡が空") }
        XCTAssertNil(track.rect(atSourceTime: 1.8), "凍結後の区間が作られている")
    }

    /// キーフレームは追跡の**再開点**でもある（凍結を解除する）。
    func test_キーフレームで凍結が解けて追跡が再開する() {
        let target = mask([(0, 0.1), (1.0, 0.4), (3.0, 0.9)])
        let sut = builder(target)
        for i in 1...9 {                                           // 最初の区間は全滅させる
            sut.advance(toSourceTime: Double(i) / 10, transform: nil, imageSize: imageSize)
        }
        XCTAssertNil(sut.reseedRect)
        sut.advance(toSourceTime: 1.0, transform: nil, imageSize: imageSize)   // キーフレーム通過
        XCTAssertEqual(sut.reseedRect?.origin.x, 0.4, "キーフレーム位置から再 seed する")
        for i in 11...20 {
            sut.advance(toSourceTime: Double(i) / 10, transform: shift(0.02), imageSize: imageSize)
        }
        guard let track = sut.finish() else { return XCTFail("軌跡が空") }
        XCTAssertNotNil(track.rect(atSourceTime: 1.5), "再開した区間が軌跡に入っている")
    }

    // MARK: - 端の扱い

    /// **最後のキーフレームより後は、最後の追跡位置で止まる。**
    /// キーフレーム補間へ落とすと最後のキーフレーム位置へ逆戻りして、
    /// 「追跡していたのに急に元の場所へ飛ぶ」という最悪の見え方になる。
    func test_末尾は最後の追跡位置で止まる() {
        let target = mask([(0, 0.1)])                              // キーフレーム 1 個だけ
        let sut = builder(target)
        run(sut, frames: 10, dx: 0.05)                             // 0.1 → 0.6 まで追跡
        guard let track = sut.finish() else { return XCTFail("軌跡が空") }
        XCTAssertEqual(track.rect(atSourceTime: 1.0)?.origin.x ?? .nan, 0.6, accuracy: 1e-9)
        XCTAssertEqual(track.rect(atSourceTime: 99)?.origin.x ?? .nan, 0.6, accuracy: 1e-9,
                       "終端より後は最後の追跡位置を保持する（キーフレームへ戻らない）")
    }

    // MARK: - 品質ゲート

    /// 1 フレームで 2 倍に膨らむ変換は誤追跡。受け入れず外挿へ落とす。
    func test_1フレームの急なスケール変化は拒否する() {
        let target = mask([(0, 0.1), (2.0, 0.5)])
        let sut = builder(target)
        sut.advance(toSourceTime: 0.1,
                    transform: SimilarityTransform(scale: 2, rotation: 0, tx: 0, ty: 0),
                    imageSize: imageSize)
        guard let track = sut.finish() else { return XCTFail("軌跡が空") }
        XCTAssertEqual(track.rect(atSourceTime: 0.1)?.width ?? .nan, 0.2, accuracy: 1e-12,
                       "拒否されず 0.4 になっていたらゲートが効いていない")
    }

    /// じわじわ縮んで点になる暴走を累積スケールで止める。
    /// 1 フレーム 10% 縮小（ゲート内）を続けても、区間開始の 0.3 倍で打ち切る。
    func test_累積スケールの暴走を止める() {
        let target = mask([(0, 0.1), (5.0, 0.5)])
        let sut = builder(target)
        for i in 1...20 {
            sut.advance(toSourceTime: Double(i) / 10,
                        transform: SimilarityTransform(scale: 0.9, rotation: 0, tx: 0, ty: 0),
                        imageSize: imageSize)
        }
        guard let track = sut.finish() else { return XCTFail("軌跡が空") }
        let widths = track.segments.flatMap(\.samples).map(\.rect.width)
        XCTAssertGreaterThanOrEqual(widths.min() ?? 0, 0.2 * 0.3 - 1e-9,
                                    "区間開始の 0.3 倍より小さい矩形が記録されている")
    }

    // MARK: - 同一性

    /// **キーフレームを動かしたら軌跡は無効。** 古い軌跡が残ると手直しが画面に出ない。
    func test_キーフレームを動かした軌跡は使われない() {
        let target = mask([(0, 0.1), (1.0, 0.5)])
        let sut = builder(target)
        run(sut, frames: 10, dx: 0.03)
        guard let track = sut.finish() else { return XCTFail("軌跡が空") }
        XCTAssertTrue(track.matches(target))

        let edited = target.settingKeyframe(atSourceTime: 0.5, rect: box(0.8))
        XCTAssertFalse(track.matches(edited), "キーフレーム追加後も一致してしまっている")

        let otherClip = ObjectMask(id: target.id, anchor: .clip(clipID: UUID(), sourceID: sourceID),
                                   keyframes: target.keyframes)!
        XCTAssertFalse(track.matches(otherClip), "別クリップのマスクに一致してしまっている")
    }
}
