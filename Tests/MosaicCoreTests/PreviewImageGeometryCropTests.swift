import CoreGraphics
import XCTest
@testable import MosaicCore

/// `PreviewImageGeometry` のクロップ対応（`crop:` 引数）の契約。
///
/// **往復テストだけでは `contract = expand` のコピーでも通ってしまう。**
/// 手計算の literal を必ず併記する（`test_クロップ半分の中心が画面中心に来る`）。
final class PreviewImageGeometryCropTests: XCTestCase {
    /// コンテナと画像が一致する単純なケース（レターボックス無し）。
    private func geometry(crop: CropRect) -> PreviewImageGeometry {
        PreviewImageGeometry(containerSize: CGSize(width: 200, height: 200),
                             imageSize: CGSize(width: 200, height: 200),
                             zoom: .identity, crop: crop)
    }

    // MARK: - 既定値はビット同一

    /// `.full` で既存の換算（クロップ引数を追加する前の実装）とビット同一であること。
    /// **既存の全オーバーレイ（顔ピック・矩形・テキスト）を壊していないことの番人。**
    func test_クロップ既定値は従来の換算とビット同一() {
        let withDefault = PreviewImageGeometry(containerSize: CGSize(width: 400, height: 200),
                                               imageSize: CGSize(width: 100, height: 200), zoom: .identity)
        let withExplicitFull = PreviewImageGeometry(containerSize: CGSize(width: 400, height: 200),
                                                    imageSize: CGSize(width: 100, height: 200),
                                                    zoom: .identity, crop: .full)
        let normalized = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        XCTAssertEqual(withDefault.screenRect(from: normalized), withExplicitFull.screenRect(from: normalized))

        let screen = CGRect(x: 175, y: 100, width: 50, height: 50)
        XCTAssertEqual(withDefault.normalizedRect(from: screen), withExplicitFull.normalizedRect(from: screen))

        let point = CGPoint(x: 150, y: 100)
        XCTAssertEqual(withDefault.normalizedPoint(from: point), withExplicitFull.normalizedPoint(from: point))
        XCTAssertEqual(withDefault.rawNormalizedPoint(from: point),
                       withExplicitFull.rawNormalizedPoint(from: point))
        XCTAssertEqual(withDefault.screenPoint(from: CGPoint(x: 0.4, y: 0.6)),
                       withExplicitFull.screenPoint(from: CGPoint(x: 0.4, y: 0.6)))

        // かつ既定値なしの `.full` 明示は「クロップ無し」の元の実装と同じ計算式であること
        // （crop の分岐そのものを経由しても値が変わらない。400×200 コンテナに
        // 100×200 画像を fit すると左右にレターボックスが出るので `imageRect` は
        // (150,0,100,200) になる——`PreviewImageGeometryTests.test_imageRect_centersWithinContainer`
        // と同じ入力）。
        XCTAssertEqual(withExplicitFull.screenRect(from: CGRect(x: 0, y: 0, width: 1, height: 1)),
                       CGRect(x: 150, y: 0, width: 100, height: 200))
    }

    // MARK: - 往復

    func test_クロップ付きでも画面と正規化の往復が恒等() {
        let crop = CropRect(rect: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5))
        let geo = geometry(crop: crop)
        let normalized = CGRect(x: 0.15, y: 0.25, width: 0.5, height: 0.4)
        let screen = geo.screenRect(from: normalized)
        let back = geo.normalizedRect(from: screen)
        XCTAssertEqual(back.origin.x, normalized.origin.x, accuracy: 1e-6)
        XCTAssertEqual(back.origin.y, normalized.origin.y, accuracy: 1e-6)
        XCTAssertEqual(back.width, normalized.width, accuracy: 1e-6)
        XCTAssertEqual(back.height, normalized.height, accuracy: 1e-6)

        let point = CGPoint(x: 0.3, y: 0.4)
        let screenPoint = geo.screenPoint(from: point)
        let backPoint = geo.rawNormalizedPoint(from: screenPoint)
        XCTAssertEqual(backPoint?.x ?? .nan, point.x, accuracy: 1e-6)
        XCTAssertEqual(backPoint?.y ?? .nan, point.y, accuracy: 1e-6)
    }

    // MARK: - 手計算 literal（往復テストの自己無撞着を防ぐ本丸）

    /// クロップが右半分（出力枠の正規化座標で `(0.5, 0, 0.5, 1)`）のとき、
    /// その**クロップ領域自身の中心**（出力枠座標では `(0.75, 0.5)`——
    /// `0.5 + 0.5/2`）は画面の中心に来るはず（200×200 コンテナ・200×200 画像・
    /// レターボックス無しなので画面中心は (100,100)）。
    ///
    /// `screenPoint(from:)` の引数は常に**出力枠基準**の正規化座標（顔・矩形・
    /// テキストの保存値と同じ座標系）であり、クロップ領域自身の相対座標ではない
    /// ——ここを取り違えると往復テストは通っても実際の位置がずれる。
    func test_クロップ半分の中心が画面中心に来る() {
        let crop = CropRect(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let geo = geometry(crop: crop)
        let center = geo.screenPoint(from: CGPoint(x: 0.75, y: 0.5))
        XCTAssertEqual(center.x, 100, accuracy: 1e-6)
        XCTAssertEqual(center.y, 100, accuracy: 1e-6)

        // クロップ領域の左上角（出力枠座標で (0.5, 0)）が画面左上、
        // 右下角（出力枠座標で (1, 1)）が画面右下に対応することも手計算で確認する。
        let topLeft = geo.screenPoint(from: CGPoint(x: 0.5, y: 0))
        XCTAssertEqual(topLeft.x, 0, accuracy: 1e-6)
        XCTAssertEqual(topLeft.y, 0, accuracy: 1e-6)
        let bottomRight = geo.screenPoint(from: CGPoint(x: 1, y: 1))
        XCTAssertEqual(bottomRight.x, 200, accuracy: 1e-6)
        XCTAssertEqual(bottomRight.y, 200, accuracy: 1e-6)
    }

    /// `test_クロップ半分の中心が画面中心に来る` の逆写像版。**`normalizedRect`/`normalizedPoint`
    /// が通る `contractSnapped` を手計算 literal で固定する**——往復テストだけだと
    /// `contractSnapped` が `expandSnapped` のコピーでも通ってしまうので、
    /// 一方向だけの独立した期待値が要る。
    ///
    /// クロップが右半分（出力枠座標で `(0.5, 0, 0.5, 1)`）のとき、画面の中心
    /// (100,100) をタップすると、出力枠座標では `(0.75, 0.5)` になるはず
    /// （クロップ領域自身の中心は出力枠座標で `0.5 + 0.5/2 = 0.75`）。
    func test_画面中心の正規化座標はクロップ領域の中心になる() {
        let crop = CropRect(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let geo = geometry(crop: crop)
        let point = geo.normalizedPoint(from: CGPoint(x: 100, y: 100))
        XCTAssertEqual(point?.x ?? .nan, 0.75, accuracy: 1e-6)
        XCTAssertEqual(point?.y ?? .nan, 0.5, accuracy: 1e-6)

        let rawPoint = geo.rawNormalizedPoint(from: CGPoint(x: 100, y: 100))
        XCTAssertEqual(rawPoint?.x ?? .nan, 0.75, accuracy: 1e-6)
        XCTAssertEqual(rawPoint?.y ?? .nan, 0.5, accuracy: 1e-6)

        // 画面左上 (0,0) は出力枠座標でクロップ領域の左上角 (0.5, 0) になる。
        let topLeftPoint = geo.rawNormalizedPoint(from: CGPoint(x: 0, y: 0))
        XCTAssertEqual(topLeftPoint?.x ?? .nan, 0.5, accuracy: 1e-6)
        XCTAssertEqual(topLeftPoint?.y ?? .nan, 0, accuracy: 1e-6)
    }
}
