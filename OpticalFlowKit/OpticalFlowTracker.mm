// OpenCV ヘッダは Apple 系ヘッダより先に import する（NO マクロ衝突回避の定石）。
#import <opencv2/opencv.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/video/tracking.hpp>
#import "OpticalFlowTracker.h"

@implementation MMFlowMatch
- (instancetype)initWithPrevious:(NSArray<NSValue *> *)previous
                         current:(NSArray<NSValue *> *)current {
    if ((self = [super init])) {
        _previousPoints = previous;
        _currentPoints = current;
    }
    return self;
}
@end

@implementation MMFlowTrackerOptions

+ (instancetype)faceDefaults {
    MMFlowTrackerOptions *o = [[MMFlowTrackerOptions alloc] init];
    o.maxCorners = 60;
    o.qualityLevel = 0.01;
    o.minDistance = 5.0;
    o.minSurvivors = 15;
    o.minSurvivorRatio = 0.40;
    o.maxForwardBackwardError = 2.0f;
    return o;
}

+ (instancetype)objectTrackingDefaults {
    MMFlowTrackerOptions *o = [[MMFlowTrackerOptions alloc] init];
    // 点を多く・弱い特徴も拾う: 物体マスクは対象が小さいことが多く、顔向けの
    // 設定では ROI 内に 15 点も立たず seed 自体が通らない。
    o.maxCorners = 200;
    o.qualityLevel = 0.004;
    o.minDistance = 2.0;
    // 追跡側は毎フレーム seed し直す運用なので、点の脱落が累積しない。
    // 生存率のゲートは「このフレームで動きが一貫していたか」だけを見ればよく、
    // 顔向けの 40% ほど厳しくする必要がない。
    o.minSurvivors = 6;
    o.minSurvivorRatio = 0.20;
    o.maxForwardBackwardError = 2.0f;
    return o;
}

@end

namespace {
constexpr double kMaxLongSide = 640.0;   // 縮小後の長辺上限（コスト上限）

/// UIImage → 縮小グレースケール cv::Mat。scaleOut に フルフレームpx / 縮小px の係数を返す。
/// フル解像度の Mat/CGContext は確保しない: 先に縮小後サイズ (dw,dh) を計算し、
/// その縮小サイズの Mat/CGContext へ CGContextDrawImage で直接縮小描画する
/// （cv::resize は使わない。CG の補間は kCGInterpolationMedium）。
cv::Mat grayMat(UIImage *image, double &scaleOut, double maxLongSide = kMaxLongSide) {
    CGImageRef cg = image.CGImage;
    if (!cg) { scaleOut = 1.0; return cv::Mat(); }
    const size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    const double longSide = std::max(w, h);
    scaleOut = 1.0;
    size_t dw = w, dh = h;
    if (longSide > maxLongSide) {
        scaleOut = longSide / maxLongSide;
        dw = (size_t)std::lround(w / scaleOut);
        dh = (size_t)std::lround(h / scaleOut);
    }
    cv::Mat gray((int)dh, (int)dw, CV_8UC1);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    // 自前確保の CV_8UC1 Mat は連続なので bytesPerRow は幅そのもの。
    // （gray.step[0] は MatStep のヘッダ・バイナリ整合に依存し、MediaPipe 内包
    //   OpenCV 4.13 との混線デバッグ時に不正値を返した実績があるため dw を直接渡す。）
    CGContextRef ctx = CGBitmapContextCreate(gray.data, dw, dh, 8, dw,
                                             space, kCGImageAlphaNone);
    CGColorSpaceRelease(space);
    if (!ctx) { scaleOut = 1.0; return cv::Mat(); }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, dw, dh), cg);
    CGContextRelease(ctx);
    return gray;
}
}  // namespace

@implementation MMGrayFrame {
    @package
    cv::Mat _gray;   // 縮小グレースケール
    double _scale;   // フルフレームpx = 縮小px × _scale
}

+ (nullable MMGrayFrame *)frameWithImage:(UIImage *)image
                             maxLongSide:(double)maxLongSide {
    double scale = 1.0;
    cv::Mat gray = grayMat(image, scale, maxLongSide);
    if (gray.empty()) { return nil; }
    MMGrayFrame *frame = [[MMGrayFrame alloc] init];
    frame->_gray = gray;
    frame->_scale = scale;
    return frame;
}

@end

@implementation OpticalFlowTracker {
    cv::Mat _prevGray;                  // 縮小グレースケールの前フレーム
    std::vector<cv::Point2f> _points;   // 前フレームの特徴点（縮小px）
    double _scale;                      // フルフレームpx = 縮小px × _scale
    size_t _seededCount;
    MMFlowTrackerOptions *_options;
}

- (instancetype)init {
    return [self initWithOptions:[MMFlowTrackerOptions faceDefaults]];
}

- (instancetype)initWithOptions:(MMFlowTrackerOptions *)options {
    if ((self = [super init])) {
        _options = options ?: [MMFlowTrackerOptions faceDefaults];
    }
    return self;
}

- (void)reset {
    _prevGray.release();
    _points.clear();
    _seededCount = 0;
}

- (BOOL)seedWithImage:(UIImage *)image faceBox:(CGRect)faceBox {
    double scale = 1.0;
    cv::Mat gray = grayMat(image, scale);
    return [self seedWithGray:gray scale:scale faceBox:faceBox];
}

- (BOOL)seedWithGrayFrame:(MMGrayFrame *)frame faceBox:(CGRect)faceBox {
    return [self seedWithGray:frame->_gray scale:frame->_scale faceBox:faceBox];
}

- (BOOL)seedWithGray:(const cv::Mat &)gray scale:(double)scale faceBox:(CGRect)faceBox {
    if (gray.empty()) { [self reset]; return NO; }
    // 正規化 faceBox → 縮小px の ROI（画像内にクランプ）
    cv::Rect roi((int)std::lround(faceBox.origin.x * gray.cols),
                 (int)std::lround(faceBox.origin.y * gray.rows),
                 (int)std::lround(faceBox.size.width * gray.cols),
                 (int)std::lround(faceBox.size.height * gray.rows));
    roi &= cv::Rect(0, 0, gray.cols, gray.rows);
    if (roi.width < 8 || roi.height < 8) { [self reset]; return NO; }
    cv::Mat mask = cv::Mat::zeros(gray.size(), CV_8UC1);
    mask(roi).setTo(255);
    std::vector<cv::Point2f> corners;
    try {
        cv::goodFeaturesToTrack(gray, corners, _options.maxCorners, _options.qualityLevel,
                                _options.minDistance, mask);
    } catch (const cv::Exception &e) {
        NSLog(@"OpticalFlowTracker: cv::Exception in seed(goodFeaturesToTrack): %s", e.what());
        [self reset];
        return NO;
    }
    if ((int)corners.size() < _options.minSurvivors) { [self reset]; return NO; }
    _prevGray = gray;
    _points = corners;
    _scale = scale;
    _seededCount = corners.size();
    return YES;
}

- (nullable MMFlowMatch *)advanceWithImage:(UIImage *)image {
    double scale = 1.0;
    cv::Mat gray = grayMat(image, scale);
    return [self advanceWithGray:gray scale:scale];
}

- (nullable MMFlowMatch *)advanceWithGrayFrame:(MMGrayFrame *)frame {
    return [self advanceWithGray:frame->_gray scale:frame->_scale];
}

- (nullable MMFlowMatch *)advanceWithGray:(const cv::Mat &)gray scale:(double)scale {
    if (_prevGray.empty() || _points.empty()) { return nil; }
    if (gray.empty() || gray.size() != _prevGray.size()) { [self reset]; return nil; }

    std::vector<cv::Point2f> next, back;
    std::vector<uchar> stF, stB;
    std::vector<float> err;
    const cv::Size win(21, 21);
    try {
        cv::calcOpticalFlowPyrLK(_prevGray, gray, _points, next, stF, err, win, 3);
        // 前後方向チェック: next を逆向きに追跡して元の点に戻るか
        cv::calcOpticalFlowPyrLK(gray, _prevGray, next, back, stB, err, win, 3);
    } catch (const cv::Exception &e) {
        NSLog(@"OpticalFlowTracker: cv::Exception in advance(calcOpticalFlowPyrLK): %s", e.what());
        return nil;
    }

    NSMutableArray<NSValue *> *prevOut = [NSMutableArray array];
    NSMutableArray<NSValue *> *currOut = [NSMutableArray array];
    std::vector<cv::Point2f> survivors;
    for (size_t i = 0; i < _points.size(); i++) {
        if (!stF[i] || !stB[i]) { continue; }
        const float fb = cv::norm(back[i] - _points[i]);
        if (fb > _options.maxForwardBackwardError) { continue; }
        survivors.push_back(next[i]);
        // フルフレームpx へ戻して出力（相似変換の推定は Swift 側）
        [prevOut addObject:[NSValue valueWithCGPoint:
            CGPointMake(_points[i].x * _scale, _points[i].y * _scale)]];
        [currOut addObject:[NSValue valueWithCGPoint:
            CGPointMake(next[i].x * scale, next[i].y * scale)]];
    }
    const bool pass = (int)survivors.size() >= _options.minSurvivors &&
        (double)survivors.size() / (double)_seededCount >= _options.minSurvivorRatio;
    if (!pass) { [self reset]; return nil; }
    // 状態を今フレームへ前進（連続ギャップでも追跡を継続できる）
    _prevGray = gray;
    _points = survivors;
    _scale = scale;
    return [[MMFlowMatch alloc] initWithPrevious:prevOut current:currOut];
}

@end
