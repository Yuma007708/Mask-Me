// OpticalFlowKit のアンブレラヘッダ。
//
// この framework は OpenCV(opencv-spm 5.0.0) 依存を MaskMe 本体から隔離するために
// 存在する。MediaPipeTasksCommon の graph static library が OpenCV 4.13.0 を内包して
// おり（cv:: シンボルを数千個エクスポート）、アプリターゲットで OpenCV 5.0 を直接
// リンクすると 5.0 ヘッダでコンパイルしたコードが force_load 済みの 4.13 実装に解決
// されて ABI が混線する（MatStep レイアウト差で step が壊れる等）。動的 framework に
// 分離すると two-level namespace により cv:: 呼び出しがこの framework 内の 5.0 実装へ
// リンク時に束縛され、衝突が起きない。
//
// 公開 API は Foundation/UIKit 型のみ。cv:: 型をこの境界を越えて渡さないこと。
#import <UIKit/UIKit.h>

#import <OpticalFlowKit/OpticalFlowTracker.h>
