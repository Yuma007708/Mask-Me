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

namespace {
constexpr double kMaxLongSide = 640.0;   // 縮小後の長辺上限（コスト上限）
constexpr int kMaxCorners = 60;
constexpr double kQualityLevel = 0.01;
constexpr double kMinDistance = 5.0;
constexpr float kMaxFBError = 2.0f;      // 前後方向チェックの往復誤差上限（縮小px）
constexpr int kMinSurvivors = 15;
constexpr double kMinSurvivorRatio = 0.40;

/// UIImage → 縮小グレースケール cv::Mat。scaleOut に フルフレームpx / 縮小px の係数を返す。
cv::Mat grayMat(UIImage *image, double &scaleOut) {
    CGImageRef cg = image.CGImage;
    if (!cg) { scaleOut = 1.0; return cv::Mat(); }
    const size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    cv::Mat gray((int)h, (int)w, CV_8UC1);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    // 自前確保の CV_8UC1 Mat は連続なので bytesPerRow は幅そのもの。
    // （gray.step[0] は MatStep のヘッダ・バイナリ整合に依存し、MediaPipe 内包
    //   OpenCV 4.13 との混線デバッグ時に不正値を返した実績があるため w を直接渡す。）
    CGContextRef ctx = CGBitmapContextCreate(gray.data, w, h, 8, w,
                                             space, kCGImageAlphaNone);
    CGColorSpaceRelease(space);
    if (!ctx) { scaleOut = 1.0; return cv::Mat(); }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    const double longSide = std::max(w, h);
    scaleOut = 1.0;
    if (longSide > kMaxLongSide) {
        scaleOut = longSide / kMaxLongSide;
        cv::Mat small;
        try {
            cv::resize(gray, small,
                       cv::Size((int)std::lround(w / scaleOut),
                                (int)std::lround(h / scaleOut)),
                       0, 0, cv::INTER_AREA);
        } catch (const cv::Exception &e) {
            NSLog(@"OpticalFlowTracker: cv::Exception in resize: %s", e.what());
            scaleOut = 1.0;
            return cv::Mat();
        }
        return small;
    }
    return gray;
}
}  // namespace

@implementation OpticalFlowTracker {
    cv::Mat _prevGray;                  // 縮小グレースケールの前フレーム
    std::vector<cv::Point2f> _points;   // 前フレームの特徴点（縮小px）
    double _scale;                      // フルフレームpx = 縮小px × _scale
    size_t _seededCount;
}

- (void)reset {
    _prevGray.release();
    _points.clear();
    _seededCount = 0;
}

- (BOOL)seedWithImage:(UIImage *)image faceBox:(CGRect)faceBox {
    double scale = 1.0;
    cv::Mat gray = grayMat(image, scale);
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
        cv::goodFeaturesToTrack(gray, corners, kMaxCorners, kQualityLevel,
                                kMinDistance, mask);
    } catch (const cv::Exception &e) {
        NSLog(@"OpticalFlowTracker: cv::Exception in seed(goodFeaturesToTrack): %s", e.what());
        [self reset];
        return NO;
    }
    if ((int)corners.size() < kMinSurvivors) { [self reset]; return NO; }
    _prevGray = gray;
    _points = corners;
    _scale = scale;
    _seededCount = corners.size();
    return YES;
}

- (nullable MMFlowMatch *)advanceWithImage:(UIImage *)image {
    if (_prevGray.empty() || _points.empty()) { return nil; }
    double scale = 1.0;
    cv::Mat gray = grayMat(image, scale);
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
        if (fb > kMaxFBError) { continue; }
        survivors.push_back(next[i]);
        // フルフレームpx へ戻して出力（相似変換の推定は Swift 側）
        [prevOut addObject:[NSValue valueWithCGPoint:
            CGPointMake(_points[i].x * _scale, _points[i].y * _scale)]];
        [currOut addObject:[NSValue valueWithCGPoint:
            CGPointMake(next[i].x * scale, next[i].y * scale)]];
    }
    const bool pass = (int)survivors.size() >= kMinSurvivors &&
        (double)survivors.size() / (double)_seededCount >= kMinSurvivorRatio;
    if (!pass) { [self reset]; return nil; }
    // 状態を今フレームへ前進（連続ギャップでも追跡を継続できる）
    _prevGray = gray;
    _points = survivors;
    _scale = scale;
    return [[MMFlowMatch alloc] initWithPrevious:prevOut current:currOut];
}

@end
