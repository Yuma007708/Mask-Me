import Foundation

/// 書き出し失敗の原因分類とユーザー向け文言。
///
/// 従来はエクスポートの失敗がすべて「エクスポートに失敗しました」に潰れていて、
/// ユーザーが次に何をすればよいか（容量を空ける／他アプリを閉じる／別素材を選ぶ）が
/// 分からなかった。ここで `NSError` の domain / code を原因へ写して文言を出し分ける。
///
/// **`MosaicCore` は AVFoundation を import しない**（アーキテクチャ規約）ため、
/// `AVError` の値は定数名ではなく数値で持つ。値は実 SDK ヘッダ
/// `AVFoundation/AVError.h`（`AVFoundationErrorDomain`）で確認したもので、
/// 各 case に定数名をコメントで残してある。
public enum ExportFailureReason: String, Equatable, Sendable, CaseIterable {
    /// 保存先の空き容量が足りない。
    case diskFull
    /// 保存先への書き込み権限が無い。
    case permissionDenied
    /// 素材の読み込み（デコード）に失敗した。
    case decodeFailed
    /// 出力の書き込み（エンコード）に失敗した。
    case encodeFailed
    /// 割り込み（電話・メディアサービスのリセット等）で中断した。
    case interrupted
    /// メモリ不足。
    case outOfMemory
    /// DRM 等で保護された素材のため書き出せない。
    case protectedContent
    /// 上記のいずれにも当てはまらない。
    case unknown

    /// AVFoundation のエラードメイン（`AVFoundationErrorDomain`）。
    /// core は AVFoundation を import しないので文字列で持つ。
    public static let avFoundationErrorDomain = "AVFoundationErrorDomain"

    /// `NSError` の domain / code から原因を判定する。
    ///
    /// 既知の組み合わせ以外はすべて `.unknown` に落とす（誤った断定で
    /// 「容量を空けてください」のような的外れな指示を出さないため）。
    public static func classify(domain: String, code: Int) -> ExportFailureReason {
        switch domain {
        case avFoundationErrorDomain:
            return classifyAVFoundation(code: code)
        case NSCocoaErrorDomain:
            // Foundation は core で import 済みなのでシンボルで判定する。
            switch CocoaError.Code(rawValue: code) {
            case .fileWriteOutOfSpace: return .diskFull
            case .fileWriteNoPermission: return .permissionDenied
            default: return .unknown
            }
        default:
            return .unknown
        }
    }

    /// `AVFoundationErrorDomain` の code → 原因。値の出典は `AVFoundation/AVError.h`。
    private static func classifyAVFoundation(code: Int) -> ExportFailureReason {
        switch code {
        case -11801: return .outOfMemory        // AVErrorOutOfMemory
        case -11807: return .diskFull           // AVErrorDiskFull
        case -11818: return .interrupted        // AVErrorSessionWasInterrupted
        case -11819: return .interrupted        // AVErrorMediaServicesWereReset
        case -11821: return .decodeFailed       // AVErrorDecodeFailed
        case -11831: return .protectedContent   // AVErrorContentIsProtected
        case -11834: return .encodeFailed       // AVErrorEncoderNotFound
        case -11840: return .encodeFailed       // AVErrorEncoderTemporarilyUnavailable
        default: return .unknown
        }
    }

    /// ユーザー向け文言（日本語）。
    ///
    /// 「何が起きたか」だけでなく「次に何をすればよいか」を必ず含める
    /// （原因を出し分ける目的が、ユーザーの次の行動を決められるようにすることなので）。
    public var message: String {
        switch self {
        case .diskFull:
            return "端末の空き容量が足りません。写真や動画を整理してから、もう一度書き出してください。"
        case .permissionDenied:
            return "保存先へ書き込めませんでした。設定でこのアプリの写真へのアクセスを許可してから、もう一度お試しください。"
        case .decodeFailed:
            return "素材を読み込めませんでした。動画が壊れているか、対応していない形式の可能性があります。別の素材でお試しください。"
        case .encodeFailed:
            return "動画の書き出しに失敗しました。時間をおいてから、もう一度お試しください。"
        case .interrupted:
            return "書き出しが中断されました。通話や他のアプリの録画・再生を終えてから、もう一度お試しください。"
        case .outOfMemory:
            return "メモリが足りません。他のアプリを終了するか、書き出す範囲を短くしてもう一度お試しください。"
        case .protectedContent:
            return "保護された素材は書き出せません。別の素材を選んでください。"
        case .unknown:
            return "エクスポートに失敗しました。時間をおいてから、もう一度お試しください。"
        }
    }
}
