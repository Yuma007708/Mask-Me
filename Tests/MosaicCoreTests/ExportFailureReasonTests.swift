import Foundation
import XCTest
@testable import MosaicCore

final class ExportFailureReasonTests: XCTestCase {
    private let avDomain = ExportFailureReason.avFoundationErrorDomain

    /// AVFoundation の既知 code が原因へ写ること（値の出典は AVFoundation/AVError.h）。
    func test_classifyAVFoundationCodes() {
        let expected: [Int: ExportFailureReason] = [
            -11801: .outOfMemory,       // AVErrorOutOfMemory
            -11807: .diskFull,          // AVErrorDiskFull
            -11818: .interrupted,       // AVErrorSessionWasInterrupted
            -11819: .interrupted,       // AVErrorMediaServicesWereReset
            -11821: .decodeFailed,      // AVErrorDecodeFailed
            -11831: .protectedContent,  // AVErrorContentIsProtected
            -11834: .encodeFailed,      // AVErrorEncoderNotFound
            -11840: .encodeFailed       // AVErrorEncoderTemporarilyUnavailable
        ]
        for (code, reason) in expected {
            XCTAssertEqual(ExportFailureReason.classify(domain: avDomain, code: code), reason,
                           "code \(code)")
        }
    }

    /// Foundation 側（NSCocoaErrorDomain）の書き込みエラーが写ること。
    func test_classifyCocoaWriteErrors() {
        XCTAssertEqual(ExportFailureReason.classify(domain: NSCocoaErrorDomain,
                                                    code: CocoaError.Code.fileWriteOutOfSpace.rawValue),
                       .diskFull)
        XCTAssertEqual(ExportFailureReason.classify(domain: NSCocoaErrorDomain,
                                                    code: CocoaError.Code.fileWriteNoPermission.rawValue),
                       .permissionDenied)
    }

    /// 未知の domain / code は .unknown に落ちること（誤った断定をしない）。
    func test_classifyUnknownFallsBack() {
        XCTAssertEqual(ExportFailureReason.classify(domain: avDomain, code: 0), .unknown)
        XCTAssertEqual(ExportFailureReason.classify(domain: avDomain, code: -99999), .unknown)
        XCTAssertEqual(ExportFailureReason.classify(domain: NSCocoaErrorDomain, code: 0), .unknown)
        // domain が違えば同じ code でも判定しない（AVError の code を Cocoa と取り違えない）。
        XCTAssertEqual(ExportFailureReason.classify(domain: NSCocoaErrorDomain, code: -11807), .unknown)
        XCTAssertEqual(ExportFailureReason.classify(domain: "MyOwnDomain", code: -11807), .unknown)
        XCTAssertEqual(ExportFailureReason.classify(domain: "", code: -11807), .unknown)
    }

    /// domain 判定は完全一致であること（部分一致で誤判定しない）。
    func test_classifyDomainMatchIsExact() {
        XCTAssertEqual(ExportFailureReason.classify(domain: "AVFoundationErrorDomainExtra", code: -11807),
                       .unknown)
        XCTAssertEqual(ExportFailureReason.classify(domain: "avfoundationerrordomain", code: -11807),
                       .unknown)
    }

    /// すべての原因が空でない日本語文言を持ち、互いに重複しないこと
    /// （文言を出し分ける目的なので、同一文言が混ざっていたら意味がない）。
    func test_everyReasonHasDistinctMessage() {
        var seen = Set<String>()
        for reason in ExportFailureReason.allCases {
            XCTAssertFalse(reason.message.isEmpty, "\(reason)")
            XCTAssertTrue(seen.insert(reason.message).inserted, "重複した文言: \(reason)")
        }
        XCTAssertEqual(seen.count, ExportFailureReason.allCases.count)
    }

    /// rawValue は下書き・ログでの識別に使うので固定しておく。
    func test_rawValuesAreStable() {
        XCTAssertEqual(ExportFailureReason.diskFull.rawValue, "diskFull")
        XCTAssertEqual(ExportFailureReason.unknown.rawValue, "unknown")
        XCTAssertEqual(ExportFailureReason.allCases.count, 8)
    }
}
