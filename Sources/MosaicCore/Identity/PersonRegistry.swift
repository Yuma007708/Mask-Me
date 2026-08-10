import Foundation

/// 1 人分の署名の集まり。
///
/// 平均 1 本ではなく**手本を複数持つ**。同一人物でも向き・表情・光で埋め込みは動き、
/// 平均だけだと「どの向きにも中途半端に似ている」ベクトルになって、
/// 実測で 0.84 あった同一人物の類似度が目減りするため。照合は手本の**最大**類似度で行う。
public struct PersonProfile: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    /// 手本。追加順ではなく「既存の手本と最も似ていないもの」を残す（`add` 参照）。
    public private(set) var exemplars: [FaceSignature]

    /// 保持する手本の上限。増やすほど向きの網羅は上がるが、照合が線形に重くなる。
    public static let maximumExemplars = 8

    public init(id: UUID = UUID(), exemplars: [FaceSignature]) {
        self.id = id
        self.exemplars = Array(exemplars.prefix(Self.maximumExemplars))
    }

    /// この人物との類似度（手本の最大）。手本が無ければ -1。
    public func similarity(to signature: FaceSignature) -> Float {
        exemplars.map { $0.similarity(to: signature) }.max() ?? -1
    }

    /// 手本を足す。上限に達していたら「最も冗長な手本」（他の手本と最も似ているもの）を
    /// 捨てて入れ替える。単純な先頭切り捨てだと、同じ向きの手本ばかりが残る。
    public mutating func add(_ signature: FaceSignature) {
        exemplars.append(signature)
        guard exemplars.count > Self.maximumExemplars else { return }
        var mostRedundant = 0
        var highestKinship: Float = -.infinity
        for (i, candidate) in exemplars.enumerated() {
            // 自分以外との最大類似度＝「他で代用できる度合い」
            let kinship = exemplars.enumerated()
                .filter { $0.offset != i }
                .map { $0.element.similarity(to: candidate) }
                .max() ?? -1
            if kinship > highestKinship {
                highestKinship = kinship
                mostRedundant = i
            }
        }
        exemplars.remove(at: mostRedundant)
    }
}

/// 署名を人物へまとめる台帳。
///
/// 事前スキャンで動画全体の顔を流し込むと、同一人物の検出が 1 つの `PersonProfile` に
/// まとまる。顔一覧を「検出された顔の数」ではなく「写っている人の数」で見せるための土台。
public struct PersonRegistry: Sendable, Equatable, Codable {
    public private(set) var persons: [PersonProfile]

    public init(persons: [PersonProfile] = []) {
        self.persons = persons
    }

    /// 署名を台帳へ入れ、対応する人物の ID を返す。
    ///
    /// 既存の人物と `FaceIdentityThreshold.match` 以上で似ていればその人物へ手本を足す。
    /// どの人物とも似ていなければ新しい人物として登録する。
    /// **`distinct` 〜 `match` の間（判断保留の帯）に落ちた署名は、どこにも入れない**
    /// （曖昧な署名を手本にすると、その人物の輪郭が回を追うごとにぼやける）。
    @discardableResult
    public mutating func register(_ signature: FaceSignature) -> UUID? {
        var bestIndex: Int?
        var bestSimilarity: Float = -.infinity
        for (i, person) in persons.enumerated() {
            let similarity = person.similarity(to: signature)
            if similarity > bestSimilarity {
                bestSimilarity = similarity
                bestIndex = i
            }
        }
        if let index = bestIndex, bestSimilarity >= FaceIdentityThreshold.match {
            persons[index].add(signature)
            return persons[index].id
        }
        if bestIndex != nil, bestSimilarity > FaceIdentityThreshold.distinct {
            return nil   // 判断保留。手本にも新規人物にもしない
        }
        let person = PersonProfile(exemplars: [signature])
        persons.append(person)
        return person.id
    }

    /// **既に人物が決まっている**顔の署名を、その人物の手本へ足す。
    ///
    /// 追跡の続いているターゲットに `register` を使うと、向きや光で類似度が落ちた瞬間に
    /// 別人として新規登録され、同じ人が一覧で 2 人に割れる。そこで人物を指定して足す口を
    /// 分けている。ただし**その人物と `match` 以上で似ているときだけ**足す。
    /// 位置追跡が隣の人へ乗り移っていた場合に、別人の顔を手本として取り込むと
    /// その人物の輪郭が壊れ、以後の判定がまとめて狂うため。
    ///
    /// - Returns: 実際に手本として足したか。
    @discardableResult
    public mutating func addExemplar(_ signature: FaceSignature, toPersonWith id: UUID) -> Bool {
        guard let index = persons.firstIndex(where: { $0.id == id }) else { return false }
        guard persons[index].similarity(to: signature) >= FaceIdentityThreshold.match else {
            return false
        }
        persons[index].add(signature)
        return true
    }

    /// 保存されていた人物を台帳へ取り込む（下書きの復元）。
    ///
    /// **ID をそのまま残す**のが要点。下書きに保存した目印は人物 ID で顔を指しているので、
    /// ここで振り直すと目印がどの人物とも結び付かなくなる。
    /// 既に同じ ID の人物が居れば何もしない（復元は 1 回きりで、手本を二重に積む意味が無い）。
    public mutating func merge(_ profiles: [PersonProfile]) {
        for profile in profiles where !persons.contains(where: { $0.id == profile.id }) {
            persons.append(profile)
        }
    }

    /// 署名に最も近い人物（`match` 以上のときだけ）。台帳は変えない。
    public func person(matching signature: FaceSignature) -> PersonProfile? {
        persons
            .map { ($0, $0.similarity(to: signature)) }
            .filter { $0.1 >= FaceIdentityThreshold.match }
            .max { $0.1 < $1.1 }?
            .0
    }

    public func person(id: UUID) -> PersonProfile? {
        persons.first { $0.id == id }
    }
}
