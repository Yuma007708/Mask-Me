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
        case .colorGrade, .transform:
            // 色調補正・向きは ON/OFF フラグを持たない（`EditorDockRoute` の doc）。
            // 粗さスライダーとも無関係なので `activeTab` は触らない対象のまま。
            activeTab = nil
        case .face:
            activeTab = .face
            setEffectOn(.face)
        case .background:
            activeTab = .background
            setEffectOn(.background)
        case .rectangle:
            // **顔モザイクは点けない。** 矩形は矩形として独立に ON/OFF する
            // （`objectMosaicOn`）。ここで `setEffectOn(.face)` を呼んでいた頃は、
            // 矩形を 1 個置くだけのつもりで顔モザイクまで点いていた。
            //
            // 粗さは顔側のスライダーを共用する（矩形も `faceBlockSize` で描く）。
            // `activeTab` は粗さの対象を指すだけで効果の ON/OFF ではないので、
            // 顔が OFF のまま `.face` を指していてよい（didSet が矩形ツールを
            // 下ろさない条件でもある）。
            activeTab = .face
            setObjectEffectOn()
            isRectangleToolActive = true
        }
    }

    /// 矩形モザイクを ON にする（既に ON なら区間の確保だけ）。
    ///
    /// `setEffectOn` と同じ理由で**フラグより先に区間を確保する**
    /// （区間 0 本は「全区間 OFF」なので、フラグだけ立てても何も描かれない）。
    private func setObjectEffectOn() {
        ensureApplyRangesExist()
        guard !objectMosaicOn else { return }
        objectMosaicOn = true
        commitEdit()
    }

    /// 効果を ON にする（既に ON なら何もしない）。
    ///
    /// `tapTab` を使わないのは、あれが**トグル**だから。段に入るたびにトグルすると
    /// 「顔の段へ入り直したら顔モザイクが消えた」になる。
    private func setEffectOn(_ tab: EffectTab) {
        // **フラグより先に区間を確保する。** 区間 0 本は「全区間 OFF」なので、
        // フラグだけ立てても何も描かれない。既に ON でも通すこと: 「効果は ON のまま
        // 加工レイヤーだけ消した」状態から段に入り直したとき、`guard` で早期 return
        // すると区間が復活せず、完了を押しても何も起きない（ユーザー報告）。
        ensureApplyRangesExist()
        switch tab {
        case .face:
            // **顔探しはここが起点。** 動画を開いた時点では走らせていないので
            // （素材を見たいだけの人に待ち時間を負わせない）、掛けると決めた
            // このタイミングで一度だけ走らせる。2 度目以降は即座に返る。
            Task { await seedFacesIfNeeded() }
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
        case .face:
            faceMosaicOn.toggle()
            if faceMosaicOn { ensureApplyRangesExist() }
        case .background:
            backgroundMosaicOn.toggle()
            if backgroundMosaicOn {
                ensureApplyRangesExist()
                recomputeBackgroundMask()
            }
        }
        commitEdit()
    }

    /// 矩形モザイクの ON/OFF を切り替える（段は動かさない）。
    ///
    /// `EffectTab` に `.rectangle` を足していないのは、あの列挙が写真モードの
    /// `EffectTabBar` の項目そのもの（`allCases` を並べている）だから。足すと
    /// 写真の画面に矩形タブが生える。
    public func toggleObjectMosaic() {
        objectMosaicOn.toggle()
        if objectMosaicOn { ensureApplyRangesExist() }
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
