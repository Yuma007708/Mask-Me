// MaskMe ターゲットの Swift ↔ ObjC++ ブリッジ。
// OpticalFlowTracker（OpenCV 疎 LK ラッパー）を Swift から見えるようにする。
// OpticalFlowTracker は OpenCV 依存隔離のため OpticalFlowKit(動的framework) 側にある。
#import <OpticalFlowKit/OpticalFlowTracker.h>
// MMFaceEmbedder（SFace ラッパー）。人物同定の署名を作る。同じく OpenCV 依存隔離のため
// OpticalFlowKit 側にある。
#import <OpticalFlowKit/FaceEmbedder.h>
