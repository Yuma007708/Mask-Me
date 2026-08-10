import CoreGraphics
import Foundation

/// ユーザーが手で指定する矩形モザイク。**時刻ごとのキーフレーム列**を持ち、
/// 間は線形補間、両端は clamp（最初より前は最初の位置、最後より後は最後の位置）で解決する。
///
/// 旧 `ManualRegion`（矩形 1 個・時間軸なし・全フレーム同じ位置）を吸収した後継である。
/// キーフレームが 1 個だけの `ObjectMask` は「全区間で同じ矩形」＝旧 `ManualRegion` と
/// 完全に同じ振る舞いになる。移行で静止画編集の挙動が変わらないのはこの性質による。
///
/// ## 端を clamp する理由
///
/// 「見失ったら最後の位置に残す」というユーザー決定をそのまま表現している。
/// 前端も同じ規則にすることで、キーフレーム 1 個 = 全区間、という旧互換が
/// **特別扱いなしで**成立する（前端だけ非表示にすると 1 個のときの意味が割れる）。
/// プライバシーアプリとして「隠し忘れ」より「隠しすぎ」に倒す判断でもある。
/// 時間方向の ON/OFF が要るときは `MosaicApplyRange`（適用区間）の担当。
///
/// ## アンカーを enum で分ける理由
///
/// `MosaicApplyRange` の doc が「`clipID` に既定値を置くな。どのクリップとも一致しない
/// sentinel が黙って残り、その区間が永久に効かない事故になる」と警告している。
/// `clipID: UUID?` にすると同じ罠を踏むので、**静止画編集には専用の `.still` を用意して
/// 型で区別する**。`.still` は時間軸を持たない編集（1 枚の写真を編集する画面）専用で、
/// キーフレームは常に 1 個・`sourceTime == 0`（`TimelineState.validate()` が検査する）。
public struct ObjectMask: Identifiable, Equatable, Sendable {
    /// このマスクが何に貼り付いているか。
    public enum Anchor: Codable, Equatable, Sendable {
        /// 静止画編集（時間軸なし）。キーフレームは 1 個・`sourceTime == 0` に限る。
        case still
        /// 動画クリップ。素材時刻アンカーなので、分割・並べ替え・速度変更・トリムに
        /// 書き換えなしで自動追従する（`MosaicApplyRange` と同じ規約）。
        case clip(clipID: UUID, sourceID: UUID)

        /// `.clip` のときのクリップ識別子（`.still` は nil）。
        public var clipID: UUID? {
            if case let .clip(clipID, _) = self { return clipID }
            return nil
        }

        /// `.clip` のときの素材識別子（`.still` は nil）。
        public var sourceID: UUID? {
            if case let .clip(_, sourceID) = self { return sourceID }
            return nil
        }

        /// 静止画編集（時間軸なし）か。
        public var isStill: Bool {
            if case .still = self { return true }
            return false
        }
    }

    /// ある素材時刻での矩形位置。
    public struct Keyframe: Identifiable, Codable, Equatable, Sendable {
        public let id: UUID
        /// 素材内の時刻（秒）。**合成時刻ではない。**
        public var sourceTime: Double
        /// 画像座標系の正規化矩形（0-1）。
        public var rect: CGRect
        /// 矩形の傾き（ラジアン、時計回り）。無回転は 0。
        ///
        /// **これはピクセル空間での回転角である。** 正規化座標(0-1)は画像の縦横比の
        /// ぶんだけ歪んでいるので、正規化のまま回すと画面上では平行四辺形になる。
        /// 実際に回すのは `FaceMaskBuilder.rectPath(from:angle:in:)` の中、
        /// `size` を掛けてピクセル空間へ移してから。
        ///
        /// 値域は `-π...π`（`normalizedAngle` が入口で畳む）。範囲を決めておかないと、
        /// 指をぐるぐる回した回数だけ値が増え続け、補間が何周も回る。
        public var angle: Double

        public init(id: UUID = UUID(), sourceTime: Double, rect: CGRect, angle: Double = 0) {
            self.id = id
            self.sourceTime = sourceTime
            self.rect = rect
            self.angle = ObjectMask.normalizedAngle(angle)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: KeyframeCodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            sourceTime = try container.decode(Double.self, forKey: .sourceTime)
            rect = try container.decode(CGRect.self, forKey: .rect)
            angle = ObjectMask.normalizedAngle(
                try container.decodeIfPresent(Double.self, forKey: .angle) ?? 0)
        }
    }

    // `angle` を後から足したので、**それが無い下書きも読めなければならない**
    // （合成された Codable では欠けたキーでデコードごと失敗し、下書きが丸ごと開けなくなる）。
    // 無ければ無回転として読む。`Keyframe` の中に置くと入れ子が深すぎるのでここに出す。
    enum KeyframeCodingKeys: String, CodingKey {
        case id, sourceTime, rect, angle
    }

    /// 角度を `-π...π` へ畳む。非有限は 0（無回転）。
    ///
    /// **回転ジェスチャは何周でも回せる。** 畳まずに貯めると、キーフレーム間の補間が
    /// 何周も回って「指を離した瞬間に矩形が高速回転する」ことになる。
    public static func normalizedAngle(_ angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        let twoPi = Double.pi * 2
        var wrapped = angle.truncatingRemainder(dividingBy: twoPi)
        if wrapped > .pi { wrapped -= twoPi }
        if wrapped < -.pi { wrapped += twoPi }
        return wrapped
    }

    public let id: UUID
    public var anchor: Anchor

    /// 素材時刻の昇順・同時刻の重複なし・**非空**が保たれたキーフレーム列。
    ///
    /// 直接代入させないのは、この 3 つが崩れると `rect(atSourceTime:)` の補間が
    /// 黙って別の区間を引く（＝画面のどこか別の場所にモザイクが出る）ため。
    /// 編集は `settingKeyframe` / `movingKeyframe` / `removingKeyframe` を通す。
    public private(set) var keyframes: [Keyframe]

    /// キーフレーム列から作る。**正規化の結果が空になったら nil。**
    ///
    /// 正規化は「非有限を捨てる → 素材時刻の昇順 → 同時刻は後勝ちで 1 個に潰す」。
    /// 空のマスクは「どの時刻でも矩形が決まらない」＝存在してはいけない状態なので、
    /// 呼び出し側に必ず判断させる（黙って空を通すと補間側で nil 合体が要る）。
    public init?(id: UUID = UUID(), anchor: Anchor, keyframes: [Keyframe]) {
        let normalized = Self.normalized(keyframes)
        guard !normalized.isEmpty else { return nil }
        self.id = id
        self.anchor = anchor
        // `.still` は時間軸を持たないので、常に「時刻 0 のキーフレーム 1 個」へ畳む。
        // 検査を `TimelineState.validate()` に委ねてはいけない（呼び出しがテストにしか
        // 無く、本番では誰も落とさない）。型が入口で守る。
        self.keyframes = anchor.isStill ? Self.stillFolded(normalized) : normalized
    }

    /// キーフレーム 1 個のマスク（旧 `ManualRegion` 相当）。矩形が非有限なら nil。
    public static func single(id: UUID = UUID(), anchor: Anchor,
                              sourceTime: Double = 0, rect: CGRect) -> ObjectMask? {
        ObjectMask(id: id, anchor: anchor,
                   keyframes: [Keyframe(sourceTime: sourceTime, rect: rect)])
    }

    // MARK: - 補間

    /// 指定した**素材時刻**での矩形。
    ///
    /// - 最初のキーフレームより前 → 最初の矩形
    /// - 最後のキーフレームより後 → 最後の矩形（＝「見失ったら最後の位置に残す」）
    /// - 間 → 前後 2 個の線形補間（x / y / width / height をそれぞれ）
    ///
    /// `sourceTime` が非有限のときは最初の矩形を返す（補間式に NaN を持ち込ませない）。
    public func rect(atSourceTime sourceTime: Double) -> CGRect {
        switch span(atSourceTime: sourceTime) {
        case let .exact(keyframe):
            return keyframe.rect
        case let .between(before, after, t):
            let interpolated = CGRect(x: lerp(before.rect.origin.x, after.rect.origin.x, t),
                                      y: lerp(before.rect.origin.y, after.rect.origin.y, t),
                                      width: lerp(before.rect.size.width, after.rect.size.width, t),
                                      height: lerp(before.rect.size.height, after.rect.size.height, t))
            // **成分ごとに有限でも、差分の計算で overflow して非有限になりうる。**
            // 例: x が -1e308 と 1e308 なら `(b - a)` が +Inf になり、t=0.5 でも x=+Inf。
            // NaN/Inf の矩形をそのまま描画・エクスポートへ流すと下流で何が起きるか読めないので、
            // 直前のキーフレームの矩形へ倒す（clamp と同じ「最後に確かだった位置」の考え方）。
            return Self.isFinite(interpolated) ? interpolated : before.rect
        }
    }

    /// 指定した**素材時刻**での傾き（ラジアン）。
    ///
    /// 端の扱いは `rect(atSourceTime:)` と同一（同じ `span(atSourceTime:)` を通る）。
    /// **別々に分岐を書かないこと**: 片方だけ端の扱いが違うと、最後のキーフレームより
    /// 後ろで「位置は最後のまま・角度だけ最初に戻る」という捻れた描画になる。
    ///
    /// 補間は**最短の回り方**。-179° と +179° を線形に補間すると 358° ぶん逆回りする。
    public func angle(atSourceTime sourceTime: Double) -> Double {
        switch span(atSourceTime: sourceTime) {
        case let .exact(keyframe):
            return keyframe.angle
        case let .between(before, after, t):
            let delta = Self.normalizedAngle(after.angle - before.angle)
            return Self.normalizedAngle(before.angle + delta * Double(t))
        }
    }

    /// 補間の位置。`rect` と `angle` が**同じ分岐**を通るための共通部。
    private enum Span {
        /// 端・単一キーフレーム・非有限時刻など、1 個へ倒したケース。
        case exact(Keyframe)
        /// 前後 2 個とその間の比率。
        case between(Keyframe, Keyframe, CGFloat)
    }

    private func span(atSourceTime sourceTime: Double) -> Span {
        // 不変条件（非空）により first / last は必ず存在する。
        let last = keyframes[keyframes.count - 1]
        // **`+Inf` は「最後より後」として last へ倒す。** `isFinite` で一括除外すると
        // 正の無限大が「最初の矩形」になり、モザイクが逆側へ飛ぶ。このプロジェクトには
        // 「+∞ の sourceEnd が合成尺・写像全体を汚染した」実測が
        // `TimelineEditOperations` の doc に残っており、非有限の時刻は実際に到達する。
        if sourceTime == .infinity { return .exact(last) }
        // NaN と -Inf は「判定不能」「最初より前」なので先頭へ倒す。
        guard sourceTime.isFinite else { return .exact(keyframes[0]) }
        if sourceTime <= keyframes[0].sourceTime { return .exact(keyframes[0]) }
        if sourceTime >= last.sourceTime { return .exact(last) }

        // 昇順なので「sourceTime を超える最初のキーフレーム」が後側。
        // 上の 2 分岐により index は 1...keyframes.count-1 に必ず入る。
        guard let index = keyframes.firstIndex(where: { $0.sourceTime > sourceTime }),
              index > 0 else {
            return .exact(last)
        }
        let before = keyframes[index - 1]
        let after = keyframes[index]
        let width = after.sourceTime - before.sourceTime
        guard width > 0 else { return .exact(before) }
        return .between(before, after, CGFloat((sourceTime - before.sourceTime) / width))
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    // MARK: - キーフレーム編集

    /// 指定した素材時刻へキーフレームを置く。**同じ時刻に既にあれば矩形を差し替える**
    /// （追加ではなく置換。同時刻 2 個は補間が壊れるので不変条件で禁止している）。
    /// 時刻か矩形が非有限なら self をそのまま返す（編集操作の「失敗時は self」契約）。
    ///
    /// - Parameter angle: 傾き（ラジアン）。
    ///
    ///   **既定値を置かないこと。** 省略できると、位置だけを動かす操作で渡し忘れた
    ///   ときに角度が無言で 0 へ戻る（＝掴んで動かしただけで傾きが失われる）。
    ///   位置だけ変えたいなら現在の角度（`angle(atSourceTime:)`）を明示的に渡す。
    ///   `MosaicApplyRange.clipID` が既定値を禁じているのと同じ理由。
    public func settingKeyframe(atSourceTime sourceTime: Double, rect: CGRect,
                                angle: Double) -> ObjectMask {
        // 時刻をグリッドへ丸めてから比較する（`timeGridPerSecond` の doc 参照。
        // 生の Double を厳密比較すると置換が起きずキーフレームが増殖する）。
        guard var time = Self.quantize(sourceTime), Self.isFinite(rect) else { return self }
        // `.still` は時間軸を持たない。「矩形を描き直す」操作は通したいので拒否ではなく
        // **時刻 0 への畳み込み**にする（キーフレーム 1 個・時刻 0 が常に保たれる）。
        if anchor.isStill { time = 0 }
        var result = self
        if let index = keyframes.firstIndex(where: { $0.sourceTime == time }) {
            result.keyframes[index].rect = rect
            result.keyframes[index].angle = Self.normalizedAngle(angle)
        } else {
            result.keyframes = Self.normalized(
                keyframes + [Keyframe(sourceTime: time, rect: rect, angle: angle)])
        }
        return result
    }

    /// キーフレームを別の素材時刻へ動かす。移動先に既存のキーフレームがあれば**それを潰す**
    /// （同時刻 2 個を作らない）。対象が無い・非有限なら self を返す。
    public func movingKeyframe(id keyframeID: UUID, toSourceTime sourceTime: Double) -> ObjectMask {
        // `.still` に時刻の移動は無い（常に時刻 0 の 1 個）。
        guard !anchor.isStill else { return self }
        guard let time = Self.quantize(sourceTime),
              let index = keyframes.firstIndex(where: { $0.id == keyframeID }) else { return self }
        var moved = keyframes
        moved[index].sourceTime = time
        // 移動先に居座っていた別のキーフレームを先に除く（`normalized` の後勝ちに任せると
        // どちらが残るかが配列順に依存して読めない）。
        moved.removeAll { $0.id != keyframeID && $0.sourceTime == time }
        var result = self
        result.keyframes = Self.normalized(moved)
        return result
    }

    /// キーフレームを 1 個消す。
    ///
    /// **最後の 1 個は消せない（nil を返す）。** これは「マスクごと消してくれ」の合図であり、
    /// 呼び出し側に必ず判断させるための設計である（空のマスクを黙って作らせない）。
    /// 対象 id が無いときは self をそのまま返す。
    public func removingKeyframe(id keyframeID: UUID) -> ObjectMask? {
        guard keyframes.contains(where: { $0.id == keyframeID }) else { return self }
        // **残りが空かどうかで判定する（`count > 1` で判定しない）。** 同じ id が
        // 複数あると `count > 1` を通ったまま `filter` が全部落として空マスクを返す。
        // id 重複は `normalized` が潰すが、判定をここでも残りの実数で行うことで
        // 「不変条件が破れても空を返さない」二重の守りにする。
        let remaining = keyframes.filter { $0.id != keyframeID }
        guard !remaining.isEmpty else { return nil }
        var result = self
        result.keyframes = remaining
        return result
    }

    // MARK: - 正規化

    /// キーフレーム時刻の量子化グリッド（1 秒あたりの刻み数）。
    ///
    /// **素材時刻を厳密比較で扱ってはいけない。** 素材時刻は
    /// `TimelineMapping.location(for:at:)` が `sourceStart + offset * rate` で
    /// 毎回計算する Double なので、同じ再生位置でも呼ぶたびに 1 ulp 単位で揺れる。
    /// 厳密比較のまま「同時刻なら置換」を判定すると一致がほぼ起きず、
    /// ドラッグのたびに 1e-16 秒差のキーフレームが増殖して、UI 上は重なって
    /// 見えるのに片方は選択も削除もできない粉塵になる。
    ///
    /// 1/600 秒 = 約 1.7ms。60fps の 1 フレーム（16.7ms）より十分細かく、
    /// CMTime の慣用 timescale とも揃う。
    public static let timeGridPerSecond: Double = 600

    /// 素材時刻をグリッドへ丸める。非有限になる入力（`±Inf` / `NaN` / 丸めで
    /// overflow する極端な値）は nil を返して呼び出し側で捨てさせる。
    static func quantize(_ time: Double) -> Double? {
        let scaled = (time * timeGridPerSecond).rounded()
        guard scaled.isFinite else { return nil }
        return scaled / timeGridPerSecond
    }

    /// 不変条件（非空・昇順・時刻重複なし・**id 重複なし**）を満たす形へ整える。
    ///
    /// 手順は「非有限を捨てて時刻を量子化 → **id 重複を後勝ちで 1 個** →
    /// 同時刻を後勝ちで 1 個 → 昇順」。
    ///
    /// **id の一意化を省いてはいけない。** 時刻だけで潰していた実装では、
    /// 同一 id の 2 個が素通りし `removingKeyframe` の `filter` が両方を落として
    /// **空の `ObjectMask` を非 nil で返し**、次の `rect(atSourceTime:)` が
    /// `keyframes[0]` で Index out of range になった（設計レビューで発見）。
    static func normalized(_ input: [Keyframe]) -> [Keyframe] {
        var cleaned: [Keyframe] = []
        for frame in input {
            guard let time = quantize(frame.sourceTime), isFinite(frame.rect) else { continue }
            var quantized = frame
            quantized.sourceTime = time
            cleaned.append(quantized)
        }
        // id 重複は後勝ち（末尾から見て初出だけ残し、並びを戻す）。
        var seenIDs: Set<UUID> = []
        var unique: [Keyframe] = []
        for frame in cleaned.reversed() where seenIDs.insert(frame.id).inserted {
            unique.append(frame)
        }
        unique.reverse()
        // 同時刻も後勝ち（`settingKeyframe` が末尾に足す運用と揃える）。
        var byTime: [Double: Keyframe] = [:]
        for frame in unique { byTime[frame.sourceTime] = frame }
        return byTime.keys.sorted().compactMap { byTime[$0] }
    }

    /// `.still` 用に「時刻 0 のキーフレーム 1 個」へ畳む。
    ///
    /// 残すのは**最初の 1 個**（時刻順で最も早いもの）。静止画には順序の意味が無いので
    /// どれを残しても等価だが、規則を固定しておかないとデコードのたびに矩形が変わる。
    private static func stillFolded(_ keyframes: [Keyframe]) -> [Keyframe] {
        guard let first = keyframes.first else { return [] }
        // **項目を書き写すこと。** ここで作り直すので、`Keyframe` に何かを足したときに
        // 移し忘れると静止画マスクでだけ黙って落ちる（角度で実際に起きた）。
        return [Keyframe(id: first.id, sourceTime: 0, rect: first.rect, angle: first.angle)]
    }

    static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
    }
}

// MARK: - Codable

extension ObjectMask: Codable {
    private enum CodingKeys: String, CodingKey { case id, anchor, keyframes }

    /// デコード時も不変条件（昇順・重複なし・非空）を通す。
    ///
    /// 手で編集された JSON や将来のスキーマ変更で壊れた配列が入ったとき、
    /// **黙って補間を壊す**より読み込みを失敗させる方が安全（矩形モザイクが
    /// 意図しない場所に出るのはプライバシー上の実害になる）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let anchor = try container.decode(Anchor.self, forKey: .anchor)
        let keyframes = try container.decode([Keyframe].self, forKey: .keyframes)
        guard let mask = ObjectMask(id: id, anchor: anchor, keyframes: keyframes) else {
            throw DecodingError.dataCorruptedError(
                forKey: .keyframes, in: container,
                debugDescription: "ObjectMask のキーフレームが空、または全て非有限だった")
        }
        self = mask
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(anchor, forKey: .anchor)
        try container.encode(keyframes, forKey: .keyframes)
    }
}
