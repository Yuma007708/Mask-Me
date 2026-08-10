import XCTest
import SwiftUI
import UIKit
@testable import MaskMe

/// 「道具の色」と「タイムラインの帯の色」が**同じ 1 つの表から来ている**ことを固定する。
///
/// ## 何を守っているか
///
/// 案 C の配色は「場所ではなく色で道具を覚える」ことが前提で、そのためには
/// **押した道具の色と、出てくる帯の色が一致していなければ意味がない**
/// （テキストを押す → 桃の帯が出る）。この対応は `AppTheme.ToolAccent` を
/// `TimelineToolItem.Role` と `TimelinePalette` の両方が引くことで成り立っている。
///
/// 表が 2 つに分かれると、画面上は「なんとなく色が付いている」だけで
/// **手がかりとして機能しなくなる**。しかも見た目は破綻しないので、
/// 目視でも既存テストでも気づけない。ここが唯一の番人になる。
///
/// UI も Metal も実素材も使わない（色の値だけを見る）。
final class ToolColorSchemeTests: XCTestCase {

    /// `Color` を sRGB の RGB 成分へ落とす。**アルファは比較に使わない**——
    /// 帯は選択状態で不透明度を変える（`opacity(0.95 : 0.6)`）ので、
    /// 色みが同じかどうかだけを見る。
    private func rgb(_ color: Color, file: StaticString = #filePath,
                     line: UInt = #line) throws -> (CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let ok = UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertTrue(ok, "sRGB へ変換できない色", file: file, line: line)
        return (r, g, b)
    }

    private func assertSameHue(_ lhs: Color, _ rhs: Color, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let left = try rgb(lhs), right = try rgb(rhs)
        XCTAssertEqual(left.0, right.0, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(left.1, right.1, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(left.2, right.2, accuracy: 0.01, message, file: file, line: line)
    }

    // MARK: - 道具 ↔ 帯

    func test_モザイクの道具と適用区間の帯が同じ色() throws {
        try assertSameHue(TimelineToolItem.Role.mask.color,
                          TimelinePalette.mosaicFill(isSelected: true),
                          "モザイクの道具と帯の色が違う（押した色と出てくる帯の色が一致しない）")
    }

    func test_音の道具とBGMの帯が同じ色() throws {
        try assertSameHue(TimelineToolItem.Role.audio.color,
                          TimelinePalette.audioFill(isSelected: true),
                          "音楽・音量の道具と BGM の帯の色が違う")
    }

    func test_文字の道具とテキストの帯が同じ色() throws {
        try assertSameHue(TimelineToolItem.Role.decorate.color,
                          TimelinePalette.textFill(isSelected: true),
                          "テキストの道具とテキストの帯の色が違う")
    }

    func test_切るの道具と継ぎ目の目印が同じ色() throws {
        try assertSameHue(TimelineToolItem.Role.cut.color, TimelinePalette.structure,
                          "分割・複製などの道具と、継ぎ目・キーフレームの目印の色が違う")
    }

    // MARK: - 表そのものの性質

    /// **5 色は互いに見分けられること。** 近い色を割り当てると
    /// 「色で覚える」が成立しない（覚えたつもりで別の道具を押す）。
    func test_役割の色は互いに十分離れている() throws {
        let roles: [(String, TimelineToolItem.Role)] = [
            ("隠す", .mask), ("音", .audio), ("文字", .decorate), ("切る", .cut), ("形", .shape)
        ]
        for i in roles.indices {
            for j in roles.indices where j > i {
                let left = try rgb(roles[i].1.color), right = try rgb(roles[j].1.color)
                let distance = sqrt(pow(left.0 - right.0, 2)
                                    + pow(left.1 - right.1, 2)
                                    + pow(left.2 - right.2, 2))
                XCTAssertGreaterThan(distance, 0.30,
                                     "「\(roles[i].0)」と「\(roles[j].0)」の色が近すぎる"
                                     + " distance=\(String(format: "%.3f", distance))")
            }
        }
    }

    /// `neutral` は**色を持たない**（素材に手を加えない操作のため）。
    /// ここが色を持つと、意味のない主張が段に増える。
    func test_neutralは本文色と同じで彩度を持たない() throws {
        let (r, g, b) = try rgb(TimelineToolItem.Role.neutral.color)
        XCTAssertEqual(max(r, g, b) - min(r, g, b), 0, accuracy: 0.10,
                       "neutral に色みが付いている rgb=(\(r), \(g), \(b))")
    }

    /// **資産の `AccentColor` が `AppTheme.accent` とずれていないこと。**
    ///
    /// システム部品（`Picker` / `Slider` / `Toggle` など）と UIKit の `tintColor` は
    /// 資産の AccentColor を引くので、ここがずれると**自作の部品だけ新配色、
    /// 標準部品だけ旧配色**という混在になる。
    ///
    /// **`Color.accentColor` を読んで比べてはいけない。** SwiftUI のそれは環境から
    /// 解決される値で、View 階層の外（＝このテスト）では OS 既定の青へ落ちる。
    /// 実際にそう書いて「資産を直したのに直らない」と読める失敗を出した。
    /// ここでは資産そのものを名前で引いて、**値だけ**を比べる。
    func test_資産のアクセント色がAppThemeと一致する() throws {
        let bundle = Bundle(for: type(of: self))
        // テストバンドルではなく**ホストアプリ**の資産を引く（資産はアプリ側にある）。
        let appBundle = Bundle(identifier: "com.maskme.app") ?? bundle
        let asset = try XCTUnwrap(UIColor(named: "AccentColor", in: appBundle, compatibleWith: nil),
                                  "資産に AccentColor が無い")
        try assertSameHue(Color(uiColor: asset), AppTheme.accent,
                          "Assets の AccentColor が AppTheme.accent とずれている"
                          + "（標準部品だけ旧配色で残る）")
    }
}
