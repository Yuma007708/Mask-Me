#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 前後方向チェックを通過した対応点ペア（フルフレームのピクセル座標）。
/// 相似変換の推定は MosaicCore.SimilarityTransform（純 Swift）側で行う。
@interface MMFlowMatch : NSObject
@property (nonatomic, readonly) NSArray<NSValue *> *previousPoints;
@property (nonatomic, readonly) NSArray<NSValue *> *currentPoints;
- (instancetype)initWithPrevious:(NSArray<NSValue *> *)previous
                         current:(NSArray<NSValue *> *)current;
@end

/// 縮小グレースケール済みの 1 フレーム（cv::Mat を内包する opaque ラッパ）。
/// 複数の OpticalFlowTracker（顔ごと）が同じフレームを追跡するとき、
/// グレー化・縮小を 1 フレーム 1 回に共有するために使う。
@interface MMGrayFrame : NSObject
/// UIImage から縮小グレーフレームを作る。maxLongSide は縮小後の長辺上限（px）。
+ (nullable MMGrayFrame *)frameWithImage:(UIImage *)image
                             maxLongSide:(double)maxLongSide
    NS_SWIFT_NAME(init(image:maxLongSide:));
@end

/// OpenCV 疎 Lucas-Kanade によるフレーム間の特徴点追跡。
/// 検出パイプラインが全滅したフレームで「画素の動き」から顔の運動を推定するための
/// 対応点ペアを供給する。OpenCV 依存はこのクラスの実装（.mm）に閉じ込める。
///
/// 品質ゲート（満たさなければ nil = フロー放棄）:
/// - 生存点 15 個以上かつ seed 時の 40% 以上
/// - 前後方向チェック: 逆追跡の往復誤差 < 2px（縮小画像空間）
/// 処理は輝度のみ・長辺 640px に縮小して行う（CI クラッシュ flaky 対策のコスト上限）。
@interface OpticalFlowTracker : NSObject
- (void)reset;
/// 検出成功フレームで呼ぶ。faceBox は正規化 [0,1]。特徴点が取れなければ NO。
- (BOOL)seedWithImage:(UIImage *)image faceBox:(CGRect)faceBox
    NS_SWIFT_NAME(seed(with:faceBox:));
/// 検出全滅フレームで呼ぶ。品質ゲート通過時のみ対応点ペアを返す。
/// 成功時は内部状態を今フレームへ前進させる（連続ギャップを追跡し続けられる）。
- (nullable MMFlowMatch *)advanceWithImage:(UIImage *)image
    NS_SWIFT_NAME(advance(with:));

/// 共有グレーフレーム版の seed（毎フレーム前進層用。グレー化を顔間で共有する）。
/// seed と advance には同一系列（同じ寸法）の MMGrayFrame を渡すこと。
- (BOOL)seedWithGrayFrame:(MMGrayFrame *)frame faceBox:(CGRect)faceBox
    NS_SWIFT_NAME(seed(grayFrame:faceBox:));
/// 共有グレーフレーム版の advance。
- (nullable MMFlowMatch *)advanceWithGrayFrame:(MMGrayFrame *)frame
    NS_SWIFT_NAME(advance(grayFrame:));
@end

NS_ASSUME_NONNULL_END
