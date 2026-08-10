import MosaicCore
import SwiftUI
import UniformTypeIdentifiers

/// タイムラインから開くシート一式の提示条件（`TimelineEditSheets.swift` から分離）。
///
/// シートの中身（速度・音量・トランジション）はあちらに置き、こちらは
/// **いつ・何を出すか**だけを持つ。file_length の都合だが、境界は意味とも合っている。
struct TimelineEditSheetsModifier: ViewModifier {
    @ObservedObject var model: MosaicEditorModel
    @Binding var speedClipID: UUID?
    @Binding var volumeTarget: TimelineVolumeAvailability.Target?
    @Binding var transitionClipID: UUID?
    @Binding var showMediaPicker: Bool
    /// 音楽ファイル選択（E2）。プレイヘッド位置に BGM を置く。
    @Binding var showAudioPicker: Bool
    /// BGM を置く合成時刻（プレイヘッド）。
    let audioInsertTime: Double
    /// テキスト入力シート（E3）。プレイヘッド位置に新規テキストを置く。
    @Binding var showTextInputSheet: Bool
    /// テキストを置く合成時刻（プレイヘッド）。
    let textInsertTime: Double

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: presenting($speedClipID)) { speedSheet }
            .sheet(isPresented: Binding(get: { volumeTarget != nil },
                                        set: { if !$0 { volumeTarget = nil } })) { volumeSheet }
            .sheet(isPresented: presenting($transitionClipID)) { transitionSheet }
            .sheet(isPresented: $showMediaPicker) {
                TimelineMediaAppendPicker(model: model) { showMediaPicker = false }
            }
            // **音楽は `.fileImporter`（ファイルアプリ）から選ぶ。**
            //
            // ミュージックアプリの曲（`MPMediaPickerController`）にしなかったのは、
            // Apple Music でダウンロードした曲が DRM 保護されていて書き出せないため。
            // 「選べたのに保存できない」が起きる経路をそもそも作らない
            // （ユーザー決定 2026-08-02）。
            .fileImporter(isPresented: $showAudioPicker,
                          allowedContentTypes: [.audio],
                          allowsMultipleSelection: false) { result in
                handleAudioImport(result)
            }
            // テキスト入力シート（E3-3a）。文面だけを受ける（見た目の設定は E3-3b）。
            .sheet(isPresented: $showTextInputSheet) {
                TimelineTextInputSheet { text in
                    model.addTextItem(text, atCompositionTime: textInsertTime)
                }
            }
    }

    /// 選んだ音楽ファイルを取り込む。
    ///
    /// **security-scoped なアクセスを開いてからアプリ内へコピーする。** 「ファイル」
    /// アプリが返す URL は他アプリのコンテナや iCloud を指すことがあり、そのまま
    /// `sources` に持つと**次に開いたときには読めない**（下書きを再開したら BGM が
    /// 鳴らない、という形で出る）。
    private func handleAudioImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let picked = urls.first else {
            if case let .failure(error) = result {
                model.errorMessage = "音楽を読み込めませんでした（\(error.localizedDescription)）"
            }
            return
        }
        let needsScope = picked.startAccessingSecurityScopedResource()
        defer { if needsScope { picked.stopAccessingSecurityScopedResource() } }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("bgm-\(UUID().uuidString).\(picked.pathExtension)")
        do {
            try FileManager.default.copyItem(at: picked, to: destination)
        } catch {
            model.errorMessage = "音楽を読み込めませんでした（\(error.localizedDescription)）"
            return
        }
        let insertTime = audioInsertTime
        Task { await model.appendAudioItem(url: destination, atCompositionTime: insertTime) }
    }

    /// 「ID が入っていたら出す・閉じたら nil に戻す」の Bool 変換。
    private func presenting(_ clipID: Binding<UUID?>) -> Binding<Bool> {
        Binding(get: { clipID.wrappedValue != nil },
                set: { if !$0 { clipID.wrappedValue = nil } })
    }

    @ViewBuilder
    private var speedSheet: some View {
        if let id = speedClipID, let clip = model.timeline.clips.first(where: { $0.id == id }) {
            // 上限はクリップ尺から決まる（合成尺が最小尺を割る倍率を選べないようにする。
            // `TimelineRateScale.maximumRate(forClip:)` の doc 参照）。
            TimelineSpeedSheet(initialRate: clip.rate,
                               maximumRate: TimelineRateScale.maximumRate(forClip: clip)) { rate in
                model.setClipRate(id: id, rate: rate)
            }
        }
    }

    /// 音量シート。**対象の種で確定先が変わる**（クリップの元音声 / BGM）。
    @ViewBuilder
    private var volumeSheet: some View {
        switch volumeTarget {
        case let .clip(id):
            if let clip = model.timeline.clips.first(where: { $0.id == id }) {
                TimelineVolumeSheet(initialVolume: clip.originalAudioVolume) { volume in
                    model.setClipVolume(id: id, volume: volume)
                }
            }
        case let .audio(id):
            if let item = model.timeline.audioItems.first(where: { $0.id == id }) {
                let fadeConfig = TimelineVolumeSheet.FadeConfig(
                    initialFadeIn: item.fadeInDuration,
                    initialFadeOut: item.fadeOutDuration,
                    maximumFade: item.duration / 2) { fadeIn, fadeOut in
                        model.setAudioFade(id: id, fadeIn: fadeIn, fadeOut: fadeOut)
                    }
                TimelineVolumeSheet(initialVolume: item.volume, fadeConfig: fadeConfig) { volume in
                    model.setAudioVolume(id: id, volume: volume)
                }
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var transitionSheet: some View {
        if let id = transitionClipID,
           let maximum = model.timeline.maximumTransitionDuration(afterClipID: id) {
            TimelineTransitionSheet(
                current: model.timeline.transitions[id],
                maximumDuration: maximum,
                onApply: { kind, duration in
                    model.setTransition(afterClipID: id, kind: kind, duration: duration)
                },
                onRemove: { model.removeTransition(afterClipID: id) })
        } else {
            Text("このつなぎ目にはトランジションを付けられません（クリップが短すぎます）")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(24)
                .presentationDetents([.height(140)])
        }
    }
}
