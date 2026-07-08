#!/bin/bash
# サンプル動画をシミュレータで検出パイプラインに通し、体誤検知が出ていないか自動チェック。
#
# 目的: 実機で確認する前に、`/Users/tatsuki/Downloads/サンプル/` の動画で
#   - 縦長bbox（体・首を顔として拾う疑い）
#   - 面積40%超のbbox（体全体を顔として拾う疑い）
# が支配的でないことをアサートする。
#
# 使い方:
#   ./verify-sample.sh           # デフォルトの Downloads/サンプル を使う
#   SAMPLE_DIR=/path ./verify-sample.sh   # 別ディレクトリを指定
#
# 通ったら実機で確認する流れ:
#   1. ./verify-sample.sh が [SAMPLE-VERIFY OK] を出すこと
#   2. ./open.sh
#   3. Xcode で Clean Build Folder → 実機 Run
set -euo pipefail

cd "$(dirname "$0")"

SAMPLE_DIR="${SAMPLE_DIR:-/Users/tatsuki/Downloads/サンプル}"

if [ ! -d "$SAMPLE_DIR" ]; then
  echo "❌ SAMPLE_DIR が存在しません: $SAMPLE_DIR"
  exit 1
fi

echo "==> 対象ディレクトリ: $SAMPLE_DIR"

# xcodegen 後の pod install を漏らすと MaskMeTests から MediaPipeTasksVision が消えて
# `#if canImport(MediaPipeTasksVision)` で守られたテストが「0 tests executed」で
# 静かに全スキップされる。毎回同期する。
echo "==> xcodegen generate"
xcodegen generate > /dev/null
echo "==> pod install（テスト target への MediaPipe 同期）"
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install > /dev/null

LOG_FILE="/tmp/maskme-verify-sample.log"
rm -f "$LOG_FILE"

echo "==> シミュレータで SampleFalsePositiveTests を実行"
set +e
SAMPLE_DIR="$SAMPLE_DIR" xcodebuild test \
  -workspace MaskMe.xcworkspace \
  -scheme MaskMe \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:MaskMeTests/SampleFalsePositiveTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  > "$LOG_FILE" 2>&1
EXIT=$?
set -e

echo ""
echo "==> サマリー"
grep "\[SAMPLE-RESULT\]" "$LOG_FILE" || echo "（サマリー行なし。$LOG_FILE を確認）"

# アサーション失敗と "0 tests" 静かスキップの両方を検出する。
EXECUTED=$(grep -Eo "Executed [0-9]+ tests" "$LOG_FILE" | head -1 | grep -Eo "[0-9]+" || echo "0")
if [ "$EXIT" -eq 0 ] && [ "$EXECUTED" -gt 0 ]; then
  echo ""
  echo "[SAMPLE-VERIFY OK] シミュレータで $EXECUTED テスト通過。体誤検知の兆候なし。"
  echo "次: ./open.sh → Xcode で Clean Build Folder → 実機 Run"
else
  echo ""
  if [ "$EXECUTED" -eq 0 ]; then
    echo "[SAMPLE-VERIFY NG] 0 tests executed. テスト target への MediaPipe 同期を確認。"
  else
    echo "[SAMPLE-VERIFY NG] 誤検知の疑いあり。$LOG_FILE を確認してください。"
  fi
  exit 1
fi
