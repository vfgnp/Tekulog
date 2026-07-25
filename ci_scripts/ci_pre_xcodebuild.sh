#!/bin/sh
#
# Xcode Cloud が xcodebuild(Archive)の直前に実行するスクリプト。
#
# 目的: ビルド番号(CFBundleVersion)を Xcode Cloud の CI_BUILD_NUMBER に自動設定する。
#   CI_BUILD_NUMBER はワークフロー単位で単調増加するため、
#   - 手動でのビルド番号バンプが一切不要になり、
#   - App Store Connect の「ビルド番号が既存と重複/以下」による
#     "Preparing build for App Store Connect failed" を恒久的に回避できる。
#
# ローカルアーカイブでは CI_BUILD_NUMBER が無いので何もしない
# (このリポジトリからのアップロードは Xcode Cloud 経由のみ。ローカル Info.plist は
#  $(CURRENT_PROJECT_VERSION) のまま git 上に残り、編集は clone 上でのみ行われる)。
#
set -e

if [ -z "$CI_BUILD_NUMBER" ]; then
  echo "ci_pre_xcodebuild: CI_BUILD_NUMBER 未設定 → スキップ"
  exit 0
fi

PLIST="$CI_PRIMARY_REPOSITORY_PATH/Tekulog/Resources/Info.plist"

echo "ci_pre_xcodebuild: CFBundleVersion を $CI_BUILD_NUMBER に設定 ($PLIST)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CI_BUILD_NUMBER" "$PLIST"
echo "ci_pre_xcodebuild: 完了 → $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
