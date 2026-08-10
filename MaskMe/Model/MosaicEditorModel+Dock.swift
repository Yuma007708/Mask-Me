import Foundation
import MosaicCore

// 下部ツールバー（動画モード）の階層移動。
//
// 段の遷移そのものは `EditorDockNavigation`（MosaicCore の純関数）が決め、
// ここは**段に紐づく副作用**だけを持つ:
// - 効果を ON にする（段に入る = その効果を使い始める）
// - 粗さスライダーの対象を合わせる（`activeTab`）
// - 矩形ツールの上げ下げ
// - 段を離れるときに編集を確定する（undo の 1 単位を段の出入りで区切る）
//
// **段を変えない操作をここに足さないこと。** シーク・再生・クリップ選択で段が
// 動くと、粗さを調整しながら再生位置を確かめる操作で段が消える（旧 UI の欠陥）。

extension MosaicEditorModel {
    /// 道具を押して 1 段降りる。降りられない組み合わせは無視する
    /// （遷移表は `EditorDockNavigation.enter` が閉じている）。
    public func enterDock(_ destination: EditorDockRoute) {
        let next = EditorDockNavigation.enter(destination, from: dockRoute)
        guard next != dockRoute else { return }
        dockRoute = next
        applyRouteSideEffects(next)
    }

    /// 戻る `‹`。1 段上がる。**効果は保つ**（段を閉じることと効果を切ることは別）。
    public func dockBack() {
        moveDock(to: EditorDockNavigation.back(from: dockRoute))
    }

    /// 完了。どの深さからでも一気に `root` へ戻す。
    public func dockDone() {
        moveDock(to: EditorDockNavigation.done(from: dockRoute))
    }

    /// 段そのものの ON/OFF（`root` へ落ちる経路で共通の後始末を通す）。
    private func moveDock(to next: EditorDockRoute) {
        guard next != dockRoute else { return }
        let leftEffectRoute = dockRoute.showsBlockSizeSlider && !next.showsBlockSizeSlider
        dockRoute = next
        if leftEffectRoute {
            // 効果の段を離れた ＝ 調整が済んだ。`confirmAdjustment` は
            // commitEdit + activeTab=nil（＝矩形ツールも下りる）の既存契約。
            confirmAdjustment()
        } else {
            applyRouteSideEffects(next)
        }
    }

    /// 段に入ったときの副作用。
    ///
    /// **効果を ON にするのは段に入った瞬間だけ。** 戻る／完了では触らない
    /// （`root` に戻っても顔モザイクは効いたまま、が設計）。
    private func applyRouteSideEffects(_ route: EditorDockRoute) {
        switch route {
        case .root, .mosaic:
            // モザイクの種類選びは、まだどの効果でもない。粗さの対象を持たせない。
            activeTab = nil
        case .face:
            activeTab = .face
            setEffectOn(.face)
        case .background:
            activeTab = .background
            setEffectOn(.background)
        case .rectangle:
            // 矩形は顔検出を補助する道具なので、粗さは顔側を使う
            // （描画も `faceMosaicOn` に従う。`MosaicEditorModel` の該当箇所参照）。
            activeTab = .face
            setEffectOn(.face)
            isRectangleToolActive = true
        }
    }

    /// 効果を ON にする（既に ON なら何もしない）。
    ///
    /// `tapTab` を使わないのは、あれが**トグル**だから。段に入るたびにトグルすると
    /// 「顔の段へ入り直したら顔モザイクが消えた」になる。
    private func setEffectOn(_ tab: EffectTab) {
        switch tab {
        case .face:
            guard !faceMosaicOn else { return }
            faceMosaicOn = true
        case .background:
            guard !backgroundMosaicOn else { return }
            backgroundMosaicOn = true
            recomputeBackgroundMask()
        }
        commitEdit()
    }

    /// 効果の ON/OFF を切り替える（段は動かさない）。
    ///
    /// **切る導線を残すために要る。** 段を降りる操作は効果を保つ契約なので、
    /// これが無いと動画モードから顔／背景モザイクを切る手段が消える。
    /// 加工をレイヤーとして直接消せるようになったら（レイヤー段の実装後）、
    /// この導線は「レイヤーを選んで削除」に一本化して外せる。
    public func toggleDockEffect(_ tab: EffectTab) {
        switch tab {
        case .face: faceMosaicOn.toggle()
        case .background:
            backgroundMosaicOn.toggle()
            if backgroundMosaicOn { recomputeBackgroundMask() }
        }
        commitEdit()
    }

    /// この段で効果が ON か（チップの点灯に使う）。
    public func isDockEffectOn(_ tab: EffectTab) -> Bool {
        switch tab {
        case .face: return faceMosaicOn
        case .background: return backgroundMosaicOn
        }
    }
}
