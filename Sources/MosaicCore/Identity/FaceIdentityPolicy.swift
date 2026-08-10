import Foundation

/// 1 つの顔にモザイクを掛けるかどうかの判断と、その理由。
///
/// 理由を持たせているのは、実素材の計測で「なぜ隠れた/隠れなかった」を
/// 数えられるようにするため（S6 の露出率・被覆率の内訳がこれで出る）。
public enum FaceIdentityDecision: Sendable, Equatable {
    /// モザイクを掛ける。
    case hide(HideReason)
    /// 素のまま残す。**確信がある場合にだけ**返る。
    case show

    public enum HideReason: Sendable, Equatable {
        /// 選択された人物だと署名で確認できた（本来の目的どおりの被覆）。
        case matchedSelectedPerson
        /// 署名は信用できるが、選択された人物と「別人と言い切る」ほど離れていない。
        case ambiguousSignature
        /// 署名が信用できず（小さい・横向き・低信頼度）、位置追跡が選択顔に当たった。
        case spatialFallback
        /// 署名も位置も決め手が無い。安全側。
        case undetermined
    }

    public var hidesFace: Bool {
        if case .hide = self { return true }
        return false
    }
}

/// 「選んだ人だけ隠す」＋「迷ったら隠す」を実装する 3 段構えの判断。
///
/// 段の順序に意味がある:
///
/// 1. **署名**（信用できるときだけ）— 見た目で人物を同定する。動画をまたいでも、
///    フレームアウトして戻ってきても効く唯一の手段。
/// 2. **位置追跡** — 署名が信用できない顔（小さい・横向き・暗い・遮蔽）の受け皿。
///    直前のフレームとの連続性しか見ないが、条件が悪い区間を渡り切るには足りる。
/// 3. **安全側** — どちらでも決まらなければ隠す。
///
/// 2 と 3 が要るのは実測が理由である。同一人物のフレーム同士でも遮蔽で 0.2030、
/// 暗所で 0.3642 まで落ち、署名だけに任せると**選んだ人が一瞬素で映る**。
/// プライバシーアプリでその露出は取り返しがつかないため、決まらない側は必ず隠す。
///
/// 代償として、**選んでいない人も条件が悪いと隠れる**。これは意図した取り引きで、
/// 逆（隠すべき人が露出する）よりましという判断による。
public enum FaceIdentityPolicy {
    /// - Parameters:
    ///   - signature: この顔の署名。埋め込みが作れなかったなら nil。
    ///   - quality: 署名を信じてよいかの計測。nil は「計測できない＝信用しない」。
    ///   - selectedPersons: モザイクを掛ける対象として選ばれた人物。
    ///   - spatiallyMatchesSelected: 位置追跡が「選択顔に当たった」と言っているか。
    public static func decide(
        signature: FaceSignature?,
        quality: FaceSignatureQuality?,
        selectedPersons: [PersonProfile],
        spatiallyMatchesSelected: Bool
    ) -> FaceIdentityDecision {
        // 誰も選んでいない = 絞り込みなし。呼び出し側で扱う契約だが、
        // ここへ来てしまった場合も「掛けない」と誤らないよう安全側にする。
        guard !selectedPersons.isEmpty else { return .hide(.undetermined) }

        if let signature, let quality, quality.isTrustworthy {
            let best = selectedPersons.map { $0.similarity(to: signature) }.max() ?? -1
            if best >= FaceIdentityThreshold.match {
                return .hide(.matchedSelectedPerson)
            }
            if best <= FaceIdentityThreshold.distinct {
                // 別人だと言い切れる。ここが唯一「確信をもって素のまま残す」経路。
                return .show
            }
            return .hide(.ambiguousSignature)
        }

        return spatiallyMatchesSelected ? .hide(.spatialFallback) : .hide(.undetermined)
    }

    /// 1 フレーム分の顔を「隠す顔」だけに絞る。**プレビューと書き出しはこの同じ関数を通す**
    /// （別々に書くと、画面では隠れているのに保存した動画では素で映る、という
    /// 最悪の食い違いが起きる）。位置追跡の当たり判定だけは経路ごとに違うため、
    /// 結果を `spatiallyMatched` として受け取る形にしてある。
    ///
    /// **判定規則: 署名は「確信があるときだけ」位置判断を覆す。**
    ///
    /// | 署名 | 結果 |
    /// |---|---|
    /// | 選んだ人だと言える（`match` 以上） | 隠す（位置が離れていても） |
    /// | 別人だと言い切れる（`distinct` 以下） | 素のまま（位置が近くても） |
    /// | 判断保留の帯・署名なし | 位置追跡の答えに従う |
    ///
    /// **`decide` の `.undetermined`（決め手なし＝隠す）をここで採らない理由**:
    /// `decide` はカメラ（既定＝全員隠す）向けの規則で、そこでは「決まらない＝隠す」が
    /// 正しい。編集画面は既定が逆（**選んだ人だけ隠す**）なので、同じ規則を当てると
    /// 署名の無いフレーム（品質ゲート落ち・間引きの谷間＝大半のフレーム）で
    /// **画面の全員が隠れ**、機能そのものが意味を失う。
    ///
    /// それでも「迷ったら隠す」は保たれている。**選んだ人でありうる顔**——位置が近い顔と、
    /// 署名が判断保留の帯にある顔——はどちらも隠れるからで、素のまま残るのは
    /// 「位置も遠く、署名も別人だと言っている」顔だけである。
    ///
    /// - Parameters:
    ///   - signatures: `faces` と**同じ順・同じ件数**。件数が違えば全て署名なしとして扱う
    ///     （取り違えて別人の署名で判定するより、位置追跡に落ちる方がまし）。
    ///   - spatiallyMatched: `faces` と同じ順。位置追跡が選択顔に当たったか。
    ///   - selectedPersons: 空なら同定は使わず、位置追跡の結果をそのまま採る
    ///     （＝人物がまだ同定できていない従来の挙動）。
    public static func hidden(
        faces: [FaceLandmarkSet],
        signatures: [FaceSignature?],
        spatiallyMatched: [Bool],
        selectedPersons: [PersonProfile]
    ) -> [FaceLandmarkSet] {
        guard spatiallyMatched.count == faces.count else { return faces }
        let usableSignatures = signatures.count == faces.count
            ? signatures
            : [FaceSignature?](repeating: nil, count: faces.count)
        return faces.indices.filter { i in
            hidesFace(signature: usableSignatures[i],
                      selectedPersons: selectedPersons,
                      spatiallyMatchesSelected: spatiallyMatched[i])
        }.map { faces[$0] }
    }

    /// `hidden` の 1 顔ぶんの判定（上表そのまま）。
    public static func hidesFace(
        signature: FaceSignature?,
        selectedPersons: [PersonProfile],
        spatiallyMatchesSelected: Bool
    ) -> Bool {
        guard !selectedPersons.isEmpty, let signature else { return spatiallyMatchesSelected }
        let best = selectedPersons.map { $0.similarity(to: signature) }.max() ?? -1
        if best >= FaceIdentityThreshold.match { return true }
        if best <= FaceIdentityThreshold.distinct { return false }
        return true   // 判断保留の帯。選んだ人でありうるので隠す
    }
}
