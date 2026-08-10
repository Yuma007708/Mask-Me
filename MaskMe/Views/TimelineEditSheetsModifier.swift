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
    /// フリーズフレームの対象時刻（表示＝合成タイムラインの時刻。プレイヘッド）。
    /// 速度シートを開いている間に再生位置が動くことは無い（シート提示中は
    /// サムネイル生成と同じ扱いで抑止される）ので、開いた瞬間の値を渡せばよい。
    let freezeTargetTime: Double
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
            // テキスト / ステッカー入力シート（E3-3a, S12）。文面・絵文字だけを受ける
            // （見た目の設定は E3-3b、`TimelineTextStyleSheet`）。
            .sheet(isPresented: $showTextInputSheet) {
                TimelineTextInputSheet(
                    onAddText: { text in model.addTextItem(text, atCompositionTime: textInsertTime) },
                    onAddSticker: { emoji in
                        model.addStickerItem(emoji, atCompositionTime: textInsertTime)
                    })
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
                               maximumRate: TimelineRateScale.maximumRate(forClip: clip),
                               freeze: freezeContext(clipID: id)) { rate in
                model.setClipRate(id: id, rate: rate)
            }
        }
    }

    /// フリーズフレーム UI 用の文脈をここで組み立てる。**活性判定は
    /// `TimelineState.canFreeze(clipID:atDisplayTime:)` をそのまま使う**
    /// （`TimelineFreezeFrameSection.Context.canFreeze` の doc 参照。別の判定を書かない）。
    private func freezeContext(clipID: UUID) -> TimelineFreezeFrameSection.Context {
        let time = freezeTargetTime
        let canFreeze = model.timeline.canFreeze(clipID: clipID, atDisplayTime: time)
        return TimelineFreezeFrameSection.Context(
            targetTimeLabel: Self.formattedTime(time),
            canFreeze: canFreeze,
            disabledReason: "この位置には挿入できません（トランジションの重なり、または"
                + "分割できない位置です）",
            loadPreview: { await model.freezeFramePreview(atDisplayTime: time) },
            performFreeze: { await model.freezeFrame(clipID: clipID, atDisplayTime: time) })
    }

    /// 「00:12.35」形式（分:秒.centi秒）。フリーズは 1 コマ単位の操作なので、
    /// 既存の transport 表示（`VideoControlsView.timeString`、秒単位）より精度を上げてある。
    private static func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.00" }
        let totalCentiseconds = Int((seconds * 100).rounded())
        let minutes = totalCentiseconds / 6000
        let secs = (totalCentiseconds / 100) % 60
        let centis = totalCentiseconds % 100
        return String(format: "%02d:%02d.%02d", minutes, secs, centis)
    }

    /// 音量シート。**対象の種で確定先が変わる**（クリップの元音声 / BGM）。
    @ViewBuilder
    private var volumeSheet: some View {
        switch volumeTarget {
        case let .clip(id):
            if let clip = model.timeline.clips.first(where: { $0.id == id }) {
                // プレイヘッドは `freezeTargetTime`（合成タイムラインの時刻）を使い回す。
                // フリーズフレーム専用の値ではなく「開いた瞬間のプレイヘッド」そのものなので、
                // 区間ミュートの起点にもそのまま使える（同ファイル冒頭の doc 参照）。
                let time = freezeTargetTime
                let muteRangeConfig = TimelineVolumeSheet.MuteRangeConfig(
                    isMutedAtPlayhead: model.isClipAudioMuted(id: id, atCompositionTime: time),
                    onToggle: { model.toggleClipAudioMute(id: id, atCompositionTime: time) })
                TimelineVolumeSheet(initialVolume: clip.originalAudioVolume,
                                   muteRangeConfig: muteRangeConfig) { volume in
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
                let duckConfig = duckingConfig(forAudioItemID: id)
                TimelineVolumeSheet(initialVolume: item.volume, fadeConfig: fadeConfig,
                                   duckingConfig: duckConfig) { volume in
                    model.setAudioVolume(id: id, volume: volume)
                }
            }
        case nil:
            EmptyView()
        }
    }

    /// 指定 BGM のダッキング（E2-3）UI 文脈。`TimelineVolumeAvailability.duckingState` が
    /// 現在状態の唯一の情報源で、ここは検出・トグルの入口（`model` の async API）を
    /// `Task` で包むだけの薄い橋渡し。対象が消えていれば nil（ボタン自体を出さない）。
    private func duckingConfig(forAudioItemID id: UUID) -> TimelineVolumeSheet.DuckingConfig? {
        guard let state = TimelineVolumeAvailability.duckingState(timeline: model.timeline,
                                                                   audioItemID: id) else { return nil }
        return TimelineVolumeSheet.DuckingConfig(
            state: state,
            onSetEnabled: { enabled, gain in
                Task { await model.setDuckingEnabled(audioItemID: id, enabled: enabled, gain: gain) }
            },
            onSelectGain: { gain in model.setDuckingGain(audioItemID: id, gain: gain) },
            onRedetect: { Task { await model.redetectDucking() } })
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
