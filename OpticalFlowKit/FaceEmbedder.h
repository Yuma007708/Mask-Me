#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// SFace（OpenCV Zoo, Apache-2.0）による顔の埋め込み。
///
/// 「見た目で人物を同定する」ための 128 次元ベクトルを作る。位置の近さでは
/// 人が動く・すれ違う・フレームアウトして戻る、で破綻するため。
///
/// **なぜ OpticalFlowKit に置くのか**: 実体は OpenCV の `cv::FaceRecognizerSF` で、
/// OpenCV 依存はこの動的 framework にだけ隔離するという規約がある（MediaPipe が
/// 内包する OpenCV 4.13 とのシンボル衝突回避。理由は OpticalFlowKit.h のコメント）。
/// 隔離境界を 2 つに増やさないため、フローと同居させている。
/// 公開 API は Foundation/UIKit 型のみ。cv:: 型をこの境界を越えて渡さないこと。
@interface MMFaceEmbedder : NSObject

/// ONNX モデルを読み込む。読めなければ nil。
/// モデルの読み込みは重いので、**1 つ作って使い回すこと**。
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
    NS_SWIFT_NAME(init(modelPath:));

/// 埋め込みの次元（SFace は 128）。
@property (class, nonatomic, readonly) NSInteger dimension;

/// 5 点で整列してから埋め込みを返す。
///
/// - Parameters:
///   - image: 元画像。
///   - alignmentPoints: **画素座標**の 5 点。順序は
///     画面左の目 → 画面右の目 → 鼻先 → 画面左の口角 → 画面右の口角。
///     順序を違えると整列が別物になり、**エラーを出さずに**同一人物の類似度だけが落ちる。
///     `MosaicCore.FaceAlignmentPoints` がこの順で作る。
/// - Returns: 128 個の NSNumber(float)。画像が読めない・点数が 5 でない場合は nil。
- (nullable NSArray<NSNumber *> *)embeddingForImage:(UIImage *)image
                                    alignmentPoints:(NSArray<NSValue *> *)alignmentPoints
    NS_SWIFT_NAME(embedding(for:alignmentPoints:));

@end

NS_ASSUME_NONNULL_END
