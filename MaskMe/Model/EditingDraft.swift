import UIKit
import MosaicCore

/// 下書きが参照する素材 1 件のメタ情報（v2）。
///
/// `id` はモデルの素材ID（`TimelineClip.sourceID`）と一致させる。復元時に
/// タイムラインのクリップと素材ファイルを結び付けるキーになる。
struct DraftSource: Codable, Equatable, Hashable {
    let id: UUID
    /// Documents/Drafts 内のコピー済み素材ファイル名。
    let fileName: String
}

/// 下書きに保存する「モザイクを掛ける対象として選択されていた顔」1 件の目印。
///
/// **顔 ID は保存しない**: `FaceTarget.id` は検出のたびに `UUID()` を振り直すため、
/// 保存しても復元時の顔とは決して一致しない（下書きを再開すると顔の選択が
/// 全部外れる不具合の原因）。そこで、`selecting(_:sourceID:targets:)` が
/// プレビュー描画で顔を突き合わせているのと**同じ作法**——素材スコープ＋
/// 正規化重心の近さ——で再照合できる情報だけを保存する。
///
/// - `centroid` は**素材フレーム基準**の正規化重心（`normalizedCentroid(of:)`）。
///   合成フレーム基準へ写した後の値を混ぜてはならない（レターボックスで座標系が
///   ずれる。`displayFaces(at:matching:)` の doc 参照）。
/// （`public`: `MosaicEditorModel.applyRestoredParameters` の引数に現れるため。
/// アプリターゲット内でのみ使う型で、外部へ公開する意図は無い。）
public struct DraftFaceSelection: Codable, Equatable, Hashable {
    /// 顔が属する素材ID（`FaceTarget.sourceID`）。写真下書き・素材ID導入前の顔は
    /// nil で、復元時は素材不問で照合される。
    public let sourceID: UUID?
    /// 選択されていた顔の正規化重心（素材フレーム基準）。
    public let centroid: CGPoint

    public init(sourceID: UUID?, centroid: CGPoint) {
        self.sourceID = sourceID
        self.centroid = centroid
    }
}

/// A persisted "work in progress" edit. Video drafts are durable (survive a
/// force-quit) so the user can resume from the Home list; the photo draft is
/// retained only across a normal background/return and is discarded on a
/// force-quit (see ``DraftStore/reconcile(photoSessionActive:)``).
struct EditingDraft: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: MediaKind
    /// File name (in Documents/Drafts) of the copied source media.
    /// v2 でも「primary（再開時に最初へロードする素材）」として維持する。
    let sourceFileName: String
    /// 参照する全素材（v2）。v1 下書きは `sourceFileName` 1 件に合成される。
    let sources: [DraftSource]
    /// タイムライン（v2）。`clips` が空なら「素材全体 1 クリップ」の意味
    /// （v1 下書き・クリップ構築前の保存）。復元時は `load(videoURL:)` の
    /// 既定経路がそのまま素材全体 1 クリップを構築する。
    let timeline: TimelineState
    let faceMosaicOn: Bool
    let backgroundMosaicOn: Bool
    let faceBlockSize: Float
    let backgroundBlockSize: Float
    /// Manual mosaic rectangles, in normalized [0,1] coordinates.
    let manualRects: [CGRect]
    /// 選択されていた顔の目印（素材ID＋正規化重心）。
    ///
    /// **nil と `[]` は意味が違う**:
    /// - nil = この下書きには顔選択の情報が無い（新フィールド導入前に保存された
    ///   下書き）。復元時は従来どおり初期スキャンの自動選択規則に落ちる。
    /// - `[]` = 保存時点でどの顔も選択されていなかった（情報としては有効）。
    let faceSelections: [DraftFaceSelection]?
    let thumbnailFileName: String?
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: MediaKind,
        sourceFileName: String,
        sources: [DraftSource]? = nil,
        timeline: TimelineState = TimelineState(),
        faceMosaicOn: Bool,
        backgroundMosaicOn: Bool,
        faceBlockSize: Float,
        backgroundBlockSize: Float,
        manualRects: [CGRect],
        faceSelections: [DraftFaceSelection]? = nil,
        thumbnailFileName: String?,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.sourceFileName = sourceFileName
        self.sources = sources ?? [DraftSource(id: UUID(), fileName: sourceFileName)]
        self.timeline = timeline
        self.faceMosaicOn = faceMosaicOn
        self.backgroundMosaicOn = backgroundMosaicOn
        self.faceBlockSize = faceBlockSize
        self.backgroundBlockSize = backgroundBlockSize
        self.manualRects = manualRects
        self.faceSelections = faceSelections
        self.thumbnailFileName = thumbnailFileName
        self.updatedAt = updatedAt
    }

    /// `sourceFileName`（再開時に最初へロードする素材）に対応する素材メタ。
    var primarySource: DraftSource? {
        sources.first { $0.fileName == sourceFileName } ?? sources.first
    }

    // 現行スキーマのキー（Encodable はこれで自動合成される）。
    private enum CodingKeys: String, CodingKey {
        case id, kind, sourceFileName, manualRects, thumbnailFileName, updatedAt
        case faceMosaicOn, backgroundMosaicOn, faceBlockSize, backgroundBlockSize
        case sources, timeline, faceSelections
    }

    // 旧スキーマ（後方互換デコード専用）。
    private enum LegacyKeys: String, CodingKey {
        case blockSize, faceEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(MediaKind.self, forKey: .kind)
        sourceFileName = try c.decode(String.self, forKey: .sourceFileName)
        manualRects = try c.decodeIfPresent([CGRect].self, forKey: .manualRects) ?? []
        thumbnailFileName = try c.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()

        // v2 フィールド。v1（キー無し）は「素材全体 1 クリップ」へ合成する:
        // - sources: 唯一の素材（sourceFileName）1 件。id はこの場で新規発行する
        //   （v1 に素材IDは存在しない。復元フローは同一デコード結果の id を
        //   一貫して使うため、値そのものは何でもよい）。
        // - timeline: 空 = 素材全体 1 クリップの意味（素材尺はデコード時点では
        //   不明なので有限のクリップは作れない。復元時に load の既定経路が
        //   実尺で構築する）。
        sources = try c.decodeIfPresent([DraftSource].self, forKey: .sources)
            ?? [DraftSource(id: UUID(), fileName: sourceFileName)]
        timeline = try c.decodeIfPresent(TimelineState.self, forKey: .timeline) ?? TimelineState()

        // 顔選択（新フィールド）。キー無しの旧下書きは nil のまま＝「情報なし」で、
        // 復元時は従来と同じ挙動（初期スキャンの自動選択規則）に落ちる。
        // `?? []` にしてはならない: 「情報なし」と「0 個選択」が区別できなくなり、
        // 旧下書きの単独の顔まで選択が外れる。
        faceSelections = try c.decodeIfPresent([DraftFaceSelection].self, forKey: .faceSelections)

        // 旧フィールド（存在すれば）。
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        let legacyFaceEnabled = (try? legacy?.decodeIfPresent(Bool.self, forKey: .faceEnabled)).flatMap { $0 }
        let legacyBlock = (try? legacy?.decodeIfPresent(Float.self, forKey: .blockSize)).flatMap { $0 }

        // 新フィールド優先 → 旧フィールド → 既定値。
        faceMosaicOn = try c.decodeIfPresent(Bool.self, forKey: .faceMosaicOn)
            ?? legacyFaceEnabled ?? true
        backgroundMosaicOn = try c.decodeIfPresent(Bool.self, forKey: .backgroundMosaicOn) ?? false
        faceBlockSize = try c.decodeIfPresent(Float.self, forKey: .faceBlockSize)
            ?? legacyBlock ?? 28
        backgroundBlockSize = try c.decodeIfPresent(Float.self, forKey: .backgroundBlockSize) ?? 28
    }
}
