import UIKit
import MosaicCore

/// 顔一覧に並べる 1 チップ分＝**1 人**。同じ人物 ID を持つ検出顔をまとめたもの。
/// 署名が取れていない顔は `members` が 1 件だけのグループになり、従来と同じ見え方になる。
public struct PersonGroup: Identifiable {
    /// 代表（一覧のサムネイル・検出率に使う）。`members` の先頭＝最初に見つかった顔。
    public let representative: FaceTarget
    public let members: [FaceTarget]

    /// 代表ターゲットの ID をそのまま使う。人物 ID を採らないのは、署名が取れていない
    /// 顔（`personID == nil`）どうしを同一視しないため。
    public var id: UUID { representative.id }
    /// まとまりの誰か 1 人でも選択されていれば選択状態として見せる。
    /// `togglePerson` が全員を揃えるので、通常は全員一致している。
    public var isSelected: Bool { members.contains { $0.isSelected } }
    public var memberIDs: [UUID] { members.map(\.id) }
    /// 検出率バッジの値。まとまりの**最大**を採る。合算しないのは、同じフレームの顔に
    /// 複数のターゲットがマッチしうるため（合算すると 100% を超える）。
    public var detectionRate: Double? { members.compactMap(\.detectionRate).max() }

    public init(representative: FaceTarget, members: [FaceTarget]) {
        self.representative = representative
        self.members = members
    }
}

/// 検出された顔1件を表すモデル。ユーザーによる選択状態と動画での検出率を持つ。
public struct FaceTarget: Identifiable {
    public let id: UUID
    /// 顔の最新既知位置。ライブ検出でマッチするたびに更新される（追加時の初期位置の
    /// まま固定すると、移動・再入した顔と重心マッチングが永久に不成立になる）。
    public var landmarks: FaceLandmarkSet
    public let thumbnail: UIImage
    public var isSelected: Bool
    /// 動画のみ: 事前スキャンで算出した検出率（0-100%）。スキャン前は nil。
    public var detectionRate: Double?
    /// この顔が検出された素材の識別子。`selectedLandmarks` の重心マッチングを
    /// 同一素材の顔に限定するために使う（別素材の似た位置の顔との誤マッチ防止）。
    /// nil は素材不問（写真モード・テスト直注入・素材ID導入前の経路）で、
    /// 従来どおり全素材の顔と照合される。
    public var sourceID: UUID?
    /// 顔の見た目（SFace 署名）で同定した人物の識別子。**署名が取れていない間は nil**。
    ///
    /// 同じ人がフレームアウト→再入して別ターゲットとして増えたとき、この ID が一致すれば
    /// 顔一覧では 1 つのチップにまとまり、選択も一緒に切り替わる（`PersonGrouping`）。
    /// nil の顔は決してまとめない（別人を巻き添えで選択解除しないため）。
    ///
    /// 再検出（`replaceDetectedFaces`）はターゲットを作り直すため、この ID は一旦 nil に戻る。
    /// **重心マッチで引き継がない**のは、それがまさに置き換えたい弱い照合だから。
    /// 台帳（`PersonRegistry`）には手本が残っているので、次に署名が取れた時点で
    /// 同じ人物 ID が付き直し、まとまりは自動的に復元される。
    public var personID: UUID?

    public init(id: UUID, landmarks: FaceLandmarkSet, thumbnail: UIImage, isSelected: Bool,
                detectionRate: Double? = nil, sourceID: UUID? = nil, personID: UUID? = nil) {
        self.id = id; self.landmarks = landmarks; self.thumbnail = thumbnail
        self.isSelected = isSelected; self.detectionRate = detectionRate; self.sourceID = sourceID
        self.personID = personID
    }
}
