// OpenCV ヘッダは Apple 系ヘッダより先に import する（NO マクロ衝突回避の定石）。
#import <opencv2/opencv.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/objdetect.hpp>
#import "FaceEmbedder.h"

namespace {
/// 元画像を縮小する長辺上限。SFace の入力は 112×112 なので大きすぎても無駄だが、
/// 小さくしすぎると引きの顔が潰れる。整列前の顔が 112px を割らない程度に残す。
constexpr double kMaxLongSide = 1920.0;

/// `cv::FaceRecognizerSF.alignCrop` が読む検出行の列数（YuNet の出力形式）。
/// [x, y, w, h, 右目x,y, 左目x,y, 鼻x,y, 右口角x,y, 左口角x,y, score]
constexpr int kFaceRowColumns = 15;

constexpr NSInteger kEmbeddingDimension = 128;
constexpr NSUInteger kAlignmentPointCount = 5;

/// UIImage → 縮小 BGR cv::Mat。scaleOut に フル画素 / 縮小画素 の係数を返す。
/// 縮小後サイズの CGContext へ直接描画する（フル解像度の中間バッファを作らない）。
cv::Mat bgrMat(UIImage *image, double &scaleOut) {
    CGImageRef cg = image.CGImage;
    if (!cg) { scaleOut = 1.0; return cv::Mat(); }
    const size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) { scaleOut = 1.0; return cv::Mat(); }
    const double longSide = std::max(w, h);
    scaleOut = 1.0;
    size_t dw = w, dh = h;
    if (longSide > kMaxLongSide) {
        scaleOut = longSide / kMaxLongSide;
        dw = (size_t)std::lround(w / scaleOut);
        dh = (size_t)std::lround(h / scaleOut);
    }
    cv::Mat bgra((int)dh, (int)dw, CV_8UC4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    // kCGBitmapByteOrder32Little + AlphaNoneSkipFirst で、メモリ上の並びが BGRA になる。
    // bytesPerRow は自前確保の連続 Mat なので dw*4（MatStep を信用しない。理由は
    // OpticalFlowTracker.mm の同じ箇所のコメント参照）。
    CGContextRef ctx = CGBitmapContextCreate(bgra.data, dw, dh, 8, dw * 4, space,
                                             kCGBitmapByteOrder32Little
                                                 | kCGImageAlphaNoneSkipFirst);
    CGColorSpaceRelease(space);
    if (!ctx) { scaleOut = 1.0; return cv::Mat(); }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, dw, dh), cg);
    CGContextRelease(ctx);

    cv::Mat bgr;
    cv::cvtColor(bgra, bgr, cv::COLOR_BGRA2BGR);
    return bgr;
}
}  // namespace

@implementation MMFaceEmbedder {
    cv::Ptr<cv::FaceRecognizerSF> _recognizer;
}

+ (NSInteger)dimension { return kEmbeddingDimension; }

- (nullable instancetype)initWithModelPath:(NSString *)modelPath {
    if (!(self = [super init])) { return nil; }
    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) { return nil; }
    try {
        _recognizer = cv::FaceRecognizerSF::create(modelPath.UTF8String, "");
    } catch (const cv::Exception &) {
        return nil;
    }
    if (_recognizer.empty()) { return nil; }
    return self;
}

- (nullable NSArray<NSNumber *> *)embeddingForImage:(UIImage *)image
                                    alignmentPoints:(NSArray<NSValue *> *)alignmentPoints {
    if (alignmentPoints.count != kAlignmentPointCount) { return nil; }

    double scale = 1.0;
    cv::Mat bgr = bgrMat(image, scale);
    if (bgr.empty()) { return nil; }

    // 5 点を縮小後の座標へ直しつつ、外接矩形も一緒に作る。
    // alignCrop が実際に使うのは 5 点だけだが、行の形式は崩さない。
    cv::Mat faceRow = cv::Mat::zeros(1, kFaceRowColumns, CV_32F);
    float minX = FLT_MAX, minY = FLT_MAX, maxX = -FLT_MAX, maxY = -FLT_MAX;
    for (NSUInteger i = 0; i < kAlignmentPointCount; ++i) {
        const CGPoint p = alignmentPoints[i].CGPointValue;
        const float x = (float)(p.x / scale), y = (float)(p.y / scale);
        if (!std::isfinite(x) || !std::isfinite(y)) { return nil; }
        faceRow.at<float>(0, 4 + (int)i * 2) = x;
        faceRow.at<float>(0, 5 + (int)i * 2) = y;
        minX = std::min(minX, x); maxX = std::max(maxX, x);
        minY = std::min(minY, y); maxY = std::max(maxY, y);
    }
    faceRow.at<float>(0, 0) = minX;
    faceRow.at<float>(0, 1) = minY;
    faceRow.at<float>(0, 2) = maxX - minX;
    faceRow.at<float>(0, 3) = maxY - minY;
    faceRow.at<float>(0, 14) = 1.0f;   // score

    cv::Mat aligned, feature;
    try {
        _recognizer->alignCrop(bgr, faceRow, aligned);
        if (aligned.empty()) { return nil; }
        _recognizer->feature(aligned, feature);
    } catch (const cv::Exception &) {
        return nil;
    }
    if (feature.empty() || feature.total() != (size_t)kEmbeddingDimension) { return nil; }

    cv::Mat flat = feature.reshape(1, 1);
    NSMutableArray<NSNumber *> *values =
        [NSMutableArray arrayWithCapacity:kEmbeddingDimension];
    for (int i = 0; i < kEmbeddingDimension; ++i) {
        [values addObject:@(flat.at<float>(0, i))];
    }
    return values;
}

@end
