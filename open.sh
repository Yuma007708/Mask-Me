#!/bin/bash
# MaskMe を最新の状態で Xcode に開く。
#
# 目的: `MaskMe.xcworkspace` を直接開くと、xcodegen で新規追加した .swift ファイルが
# 反映されず「顔検出されない」等の症状が出ることがあるため、
# xcodegen generate → pod install → open workspace を1コマンドにまとめる。
#
# 使い方: ./open.sh  （プロジェクトルートから実行）
set -euo pipefail

cd "$(dirname "$0")"

echo "==> xcodegen generate（project.yml を .xcodeproj に反映）"
xcodegen generate

# Ruby 4.0 系の CocoaPods 1.16 互換対策として LANG を強制する。
echo "==> pod install（MediaPipe のリンクを更新）"
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install

echo "==> MaskMe.xcworkspace を Xcode で開く"
open MaskMe.xcworkspace
