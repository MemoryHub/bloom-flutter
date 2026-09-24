#!/usr/bin/env bash
#
# Build the iOS release app for a connected iPhone and install it.
#
# Three things on this Mac are not where a stock Flutter setup expects them:
#
#   * `xcode-select` points at the Command Line Tools, so `xcodebuild` is not on
#     the default path. Setting `DEVELOPER_DIR` per command fixes that and needs
#     no sudo (changing the machine-wide selection does).
#   * CocoaPods lives in the user gem directory: Homebrew on this machine cannot
#     install anything ("unknown or unsupported macOS version: :sequoia"), and
#     `pod` was missing while `ios/Pods` was stale — `flutter build ios` stops at
#     "Running pod install".
#   * `flutter build ios` does not pass `-allowProvisioningUpdates`, so it fails
#     with "No profiles for 'com.zhangbo.bloom.zb20260815' were found" until the
#     profiles exist. The xcodebuild call below creates them for the team signed
#     into Xcode (4M53G7352F, a free Personal Team) and signs the app.
#
# After the very first install, iOS refuses to launch a development-signed app
# until the certificate is trusted on the phone:
#   设置 > 通用 > VPN与设备管理 > 开发者应用 > "Apple Development: …" > 信任
#
# Usage: tools/ios_install.sh [device-udid]
set -euo pipefail

DEVICE="${1:-00008101-000138CA3E84001E}" # MyiPhone12 Pro
BUNDLE_ID=com.zhangbo.bloom.zb20260815
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="$ROOT/ios/Runner.xcworkspace"
DERIVED=/tmp/bloom-dd
APP="$DERIVED/Build/Products/Release-iphoneos/Runner.app"

export PATH="/Users/zhangbo/development/flutter/bin:$HOME/.gem/ruby/2.6.0/bin:/usr/local/bin:$PATH"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

echo "==> building (Release, device)"
xcodebuild -workspace "$WORKSPACE" -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  -derivedDataPath "$DERIVED" build 2>&1 | tail -4

echo "==> installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | tail -3

echo "==> launching"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" 2>&1 | tail -3 ||
  echo "启动被系统拒绝：请在手机上 设置 > 通用 > VPN与设备管理 > 开发者应用 里信任该证书，然后再跑一次本脚本。"
