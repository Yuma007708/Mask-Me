import SwiftUI

/// フリーズフレーム挿入の UI。**独立したツールバー項目を作らず**、`TimelineSpeedSheet` に
/// 同居させる（`VideoTimelineView+Toolbar.swift` の doc が実測付きで書いているとおり、
/// 選択クリップの段は既に 7 項目あり、6 個目以降は横スクロールの向こう側 ＝ 8 個目を
/// 足しても実質「機能が無い」のと同じになる。速度シートは既に「選択したクリップ 1 本」への
/// 操作という点でフリーズと文脈が同じなので、ここへ相乗りさせるのが自然）。
///
/// シートはタイムラインを覆うため、**対象時刻とコマのサムネイルを必ず見せる。**
/// 出さないと「押したら知らない位置のコマが挟まった」になる（このファイルの存在意義）。
struct TimelineFreezeFrameSection: View {
    /// このセクションが動くのに要る値・処理を 1 つにまとめたもの。
    /// `TimelineSpeedSheet` を `model`（`MosaicEditorModel`）非依存に保つため、
    /// 呼び出し側（`TimelineEditSheetsModifier`）がここへ組み立てて渡す。
    struct Context {
        /// 「00:12.35」のように整形済みの対象時刻表示。
        let targetTimeLabel: String
        /// `TimelineState.canFreeze(clipID:atDisplayTime:)` の結果。
        /// **ボタンの活性はこれをそのまま使う**（別に判定を書くと「押せるのに
        /// 何も起きない」を作れる）。
        let canFreeze: Bool
        /// 非活性のときに添える理由（1 行）。`canFreeze == true` のときは無視される。
        let disabledReason: String
        /// 対象時刻のコマを読み取り専用で取り出す（サムネイル表示用。素材登録はしない）。
        let loadPreview: () async -> UIImage?
        /// 実際にフリーズフレームを挿入する（検出・引き継ぎ・undo 1 単位の確定まで含む）。
        let performFreeze: () async -> Void
    }

    let context: Context

    @State private var thumbnail: UIImage?
    @State private var isLoadingPreview = false
    @State private var isEncoding = false

    var body: some View {
        VStack(spacing: 10) {
            Divider()

            Text("フリーズフレーム")
                .font(.subheadline.weight(.semibold))

            HStack(alignment: .top, spacing: 12) {
                thumbnailView
                VStack(alignment: .leading, spacing: 4) {
                    Text("対象位置 \(context.targetTimeLabel)")
                        .font(.footnote)
                    if !context.canFreeze {
                        Text(context.disabledReason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Button {
                Task {
                    isEncoding = true
                    await context.performFreeze()
                    isEncoding = false
                }
            } label: {
                if isEncoding {
                    // 長 GOP 素材では tolerance 0 のデコードに時間がかかることがある
                    // （`FreezeFrameFactory` の doc 参照）。押したまま固まって見えないよう
                    // 進行表示を出す。
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("挿入中…")
                    }
                } else {
                    Text("この位置のコマを 3 秒挟む")
                }
            }
            .buttonStyle(.bordered)
            .disabled(!context.canFreeze || isEncoding)
        }
        .padding(.top, 4)
        .task(id: context.targetTimeLabel) {
            guard context.canFreeze else { return }
            isLoadingPreview = true
            thumbnail = await context.loadPreview()
            isLoadingPreview = false
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.2)
                if isLoadingPreview {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
