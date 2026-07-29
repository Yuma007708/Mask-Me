import Foundation

/// タイムラインが参照する素材 1 件のメタ情報（S6）。
///
/// `TimelineClip.sourceID` が指す素材が「何であるか」（動画か、写真由来の静止 mp4 か）を
/// 記録する。写真クリップは取り込み時に `PhotoClipEncoder`（アプリ層）で静止 mp4 へ
/// 事前エンコードされるため、composition・プレビュー・エクスポートの実行系は
/// kind を区別せず動画として扱える。kind が要るのは検出キャッシュの時刻規則
/// （写真は全フレーム同一 → 素材時刻を 0 に clamp。`TimelineState.clampedSourceTime`）だけ。
public struct TimelineSource: Identifiable, Hashable, Sendable, Codable {
    /// 素材の種別。
    public enum Kind: String, Codable, Sendable {
        /// 動画素材（既定）。
        case video
        /// 写真由来の静止 mp4。検出は素材時刻 0 の 1 回だけで全フレームに適用される。
        case photo
    }

    /// 素材の識別子（`TimelineClip.sourceID` と一致させる）。
    public let id: UUID
    public let kind: Kind

    public init(id: UUID, kind: Kind = .video) {
        self.id = id
        self.kind = kind
    }

    // MARK: - Codable（後方互換）

    private enum CodingKeys: String, CodingKey {
        case id, kind
    }

    /// `kind` キーを持たない旧 JSON（kind 導入前に保存された下書き）は
    /// 動画（`.video`）として復元する。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .video
    }
}
