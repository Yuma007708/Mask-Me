import CoreGraphics
import Foundation

/// 追跡の生サンプル列を、**ユーザーのキーフレームへ必ず着地する**軌跡へ組み直す純関数。
///
/// ## ドリフト補正（この型の存在理由）
///
/// オプティカルフローの位置は 1 フレームごとに小さな誤差が乗り、積み重なって
/// ゆっくりずれていく。区間の終わりでユーザーのキーフレームへ**跳ぶ**と、
/// そこだけモザイクが瞬間移動して非常に目立つ。
///
/// そこで「区間の終端で溜まった誤差」を、区間全体へ**時間比例で配り戻す**:
///
/// ```
/// g(t) = f(t) + (K − f(tK)) · (t − t0) / (tK − t0)
/// ```
///
/// - `g(t0) = f(t0)`（区間の入口は動かない ＝ 前の区間との継ぎ目が割れない）
/// - `g(tK) = K`（**キーフレームには誤差ゼロで着地する** ＝ ユーザーの指定が必ず勝つ）
///
/// 補正は x / y / width / height の 4 成分それぞれに掛ける（回転は矩形に持たせていない）。
public enum ObjectTrackAssembler {
    /// 生の区間列をドリフト補正して `ObjectTrack.Segment` へ。
    ///
    /// - Parameters:
    ///   - runs: 追跡が連続していた区間ごとの生サンプル（素材時刻の昇順）。
    ///     各区間は「キーフレームから始まり、次のキーフレームを跨いだところで閉じる」
    ///     ように `ObjectTrackBuilder` が切っている。
    ///   - keyframes: ユーザーのキーフレーム列（素材時刻の昇順）。
    public static func segments(runs: [[ObjectTrack.Sample]],
                                keyframes: [ObjectMask.Keyframe]) -> [ObjectTrack.Segment] {
        runs.compactMap { run in
            ObjectTrack.Segment(samples: corrected(run: run, keyframes: keyframes))
        }
    }

    /// 1 区間ぶんのドリフト補正。次のキーフレームへ**到達していない**区間は素通し
    /// （着地先が無いので配り戻す誤差が定義できない）。
    static func corrected(run: [ObjectTrack.Sample],
                          keyframes: [ObjectMask.Keyframe]) -> [ObjectTrack.Sample] {
        guard let head = run.first, let tail = run.last else { return run }
        // 区間の開始より後にある最初のキーフレームが着地先。`ObjectTrackBuilder` は
        // キーフレームを跨いだ時点で区間を閉じるので、候補は高々 1 個だが、
        // 生成側の変更に巻き込まれないようここでも「最初の 1 個」に限定する。
        guard let anchor = keyframes.first(where: { $0.sourceTime > head.sourceTime }),
              tail.sourceTime >= anchor.sourceTime,
              let rawAtAnchor = interpolate(run, at: anchor.sourceTime) else { return run }
        let span = anchor.sourceTime - head.sourceTime
        guard span > 0 else { return run }
        let error = CGRect(x: anchor.rect.origin.x - rawAtAnchor.origin.x,
                           y: anchor.rect.origin.y - rawAtAnchor.origin.y,
                           width: anchor.rect.width - rawAtAnchor.width,
                           height: anchor.rect.height - rawAtAnchor.height)
        guard ObjectMask.isFinite(error) else { return run }
        var out = run.filter { $0.sourceTime < anchor.sourceTime }.map { sample -> ObjectTrack.Sample in
            let ratio = CGFloat((sample.sourceTime - head.sourceTime) / span)
            let shifted = CGRect(x: sample.rect.origin.x + error.origin.x * ratio,
                                 y: sample.rect.origin.y + error.origin.y * ratio,
                                 width: sample.rect.width + error.width * ratio,
                                 height: sample.rect.height + error.height * ratio)
            return ObjectTrack.Sample(sourceTime: sample.sourceTime,
                                      rect: ObjectMask.isFinite(shifted) ? shifted : sample.rect)
        }
        out.append(ObjectTrack.Sample(sourceTime: anchor.sourceTime, rect: anchor.rect))
        return out
    }

    /// 生サンプル列の線形補間。範囲外は nil。
    static func interpolate(_ samples: [ObjectTrack.Sample], at time: Double) -> CGRect? {
        guard let first = samples.first, let last = samples.last,
              time >= first.sourceTime, time <= last.sourceTime else { return nil }
        guard let index = samples.firstIndex(where: { $0.sourceTime >= time }) else { return nil }
        guard index > 0 else { return first.rect }
        let before = samples[index - 1], after = samples[index]
        let span = after.sourceTime - before.sourceTime
        guard span > 0 else { return before.rect }
        let t = CGFloat((time - before.sourceTime) / span)
        return CGRect(x: before.rect.origin.x + (after.rect.origin.x - before.rect.origin.x) * t,
                      y: before.rect.origin.y + (after.rect.origin.y - before.rect.origin.y) * t,
                      width: before.rect.width + (after.rect.width - before.rect.width) * t,
                      height: before.rect.height + (after.rect.height - before.rect.height) * t)
    }
}
