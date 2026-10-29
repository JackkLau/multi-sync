#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
run_tests=false
signed=false
for argument in "$@"; do
  case "$argument" in
    --test) run_tests=true ;;
    --signed) signed=true ;;
    *) echo "用法：sh scripts/build-ios.sh [--test] [--signed]" >&2; exit 2 ;;
  esac
done
if [ "$signed" = true ]; then
  for setting in MULTISYNC_IOS_TEAM_ID MULTISYNC_IOS_SIGNING_IDENTITY MULTISYNC_IOS_PROVISIONING_PROFILE MULTISYNC_IOS_EXPORT_OPTIONS_PLIST; do
    # The setting names are fixed above; no shell evaluation of supplied values.
    if ! printenv "$setting" >/dev/null || [ -z "$(printenv "$setting")" ]; then
      echo "--signed 缺少 $setting；请先配置已有的 Apple 签名身份与描述文件。" >&2; exit 1
    fi
  done
  if [ ! -f "$MULTISYNC_IOS_EXPORT_OPTIONS_PLIST" ]; then
    echo "找不到 MULTISYNC_IOS_EXPORT_OPTIONS_PLIST 指定的导出配置。" >&2; exit 1
  fi
  if ! security find-identity -v -p codesigning | grep -Fq -- "$MULTISYNC_IOS_SIGNING_IDENTITY"; then
    echo "钥匙串中没有指定的有效 iOS 签名身份；不会输出伪装成已签名的 IPA。" >&2; exit 1
  fi
  python3 - <<'PY'
import os
import plistlib
from pathlib import Path
with Path(os.environ['MULTISYNC_IOS_EXPORT_OPTIONS_PLIST']).open('rb') as stream:
    options = plistlib.load(stream)
bundle = os.environ.get('MULTISYNC_IOS_BUNDLE_ID', 'local.multisync.mobile')
requirements = {
    'signingStyle 必须为 manual': options.get('signingStyle') == 'manual',
    'teamID 必须与 MULTISYNC_IOS_TEAM_ID 一致': options.get('teamID') == os.environ['MULTISYNC_IOS_TEAM_ID'],
    '必须明确指定导出 method': bool(options.get('method')),
    'destination 必须为 export；此脚本不上传应用': options.get('destination', 'export') == 'export',
    'provisioningProfiles 必须指定当前 bundle ID 的描述文件': bool(options.get('provisioningProfiles', {}).get(bundle)),
    '必须明确指定 signingCertificate': bool(options.get('signingCertificate')),
}
for message, valid in requirements.items():
    if not valid:
        raise SystemExit(message)
PY
fi
for tool in cargo rustup xcodegen xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "缺少 $tool。iOS 构建需要 Xcode、Rust 和 XcodeGen。" >&2; exit 1
  fi
done
case "$(uname -m)" in
  arm64) simulator_target=aarch64-apple-ios-sim ; simulator_arch=arm64 ;;
  x86_64) simulator_target=x86_64-apple-ios ; simulator_arch=x86_64 ;;
  *) echo "不支持此构建主机架构。" >&2; exit 1 ;;
esac
rustup target add aarch64-apple-ios "$simulator_target"
ios_device_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
ios_simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
mkdir -p apps/ios/Native/iphoneos apps/ios/Native/iphonesimulator dist/ios
SDKROOT="$ios_device_sdk" IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo build --locked -p multi-sync-bridge --release --target aarch64-apple-ios
SDKROOT="$ios_simulator_sdk" IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo build --locked -p multi-sync-bridge --release --target "$simulator_target"
cp target/aarch64-apple-ios/release/libmulti_sync_bridge.a apps/ios/Native/iphoneos/
cp "target/$simulator_target/release/libmulti_sync_bridge.a" apps/ios/Native/iphonesimulator/
xcodegen generate --spec apps/ios/project.yml --project apps/ios
xcodebuild -project apps/ios/MultiSyncIOS.xcodeproj -scheme MultiSync -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath .build/ios-device \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apps/ios/MultiSyncIOS.xcodeproj -scheme MultiSync -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios-simulator \
  ARCHS="$simulator_arch" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
# Use a unique staging directory; rebuilding never leaves an old app inside the IPA.
ios_stage=$(mktemp -d "$project_root/.build/ios-package.XXXXXX")
trap 'rm -rf "$ios_stage"' EXIT HUP INT TERM
mkdir -p "$ios_stage/Payload"
cp -R .build/ios-device/Build/Products/Release-iphoneos/MultiSync.app "$ios_stage/Payload/"
ditto -c -k --keepParent "$ios_stage/Payload" dist/ios/MultiSync-iOS-unsigned.ipa
ditto -c -k --keepParent .build/ios-simulator/Build/Products/Debug-iphonesimulator/MultiSync.app dist/ios/MultiSync-iOS-simulator.zip
if [ "$run_tests" = true ]; then
  xcrun simctl list devices available -j > .build/ios-simulators.json
  ios_simulator_id=$(python3 - <<'PY'
import json
from pathlib import Path
value = json.loads(Path('.build/ios-simulators.json').read_text())
candidates = []
for runtime, devices in value['devices'].items():
    if 'iOS' not in runtime:
        continue
    for device in devices:
        if device.get('isAvailable') and device['name'].startswith('iPhone'):
            candidates.append((runtime, device['name'], device['udid']))
if not candidates:
    raise SystemExit('没有可用 iPhone 模拟器；请先在 Xcode 安装 iOS Simulator runtime。')
print(sorted(candidates, reverse=True)[0][2])
PY
  )
  xcodebuild -project apps/ios/MultiSyncIOS.xcodeproj -scheme MultiSync -configuration Debug \
    -destination "platform=iOS Simulator,id=$ios_simulator_id" -derivedDataPath .build/ios-simulator \
    ARCHS="$simulator_arch" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
    -resultBundlePath "dist/ios/tests-$(date +%Y%m%d%H%M%S).xcresult" test
fi
printf '%s\n' '已构建 dist/ios/MultiSync-iOS-unsigned.ipa 和 MultiSync-iOS-simulator.zip。'
printf '%s\n' 'unsigned.ipa 未签名，真机安装需要你自己的 Apple 开发签名或分发签名。'
if [ "$signed" = true ]; then
  ios_archive="$ios_stage/MultiSync.xcarchive"
  xcodebuild -project apps/ios/MultiSyncIOS.xcodeproj -scheme MultiSync -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath .build/ios-signed \
    -archivePath "$ios_archive" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual \
    "DEVELOPMENT_TEAM=$MULTISYNC_IOS_TEAM_ID" \
    "CODE_SIGN_IDENTITY=$MULTISYNC_IOS_SIGNING_IDENTITY" \
    "PROVISIONING_PROFILE_SPECIFIER=$MULTISYNC_IOS_PROVISIONING_PROFILE" \
    "PRODUCT_BUNDLE_IDENTIFIER=${MULTISYNC_IOS_BUNDLE_ID:-local.multisync.mobile}" archive
  codesign --verify --deep --strict -R='anchor apple generic' "$ios_archive/Products/Applications/MultiSync.app"
  xcodebuild -exportArchive -archivePath "$ios_archive" \
    -exportOptionsPlist "$MULTISYNC_IOS_EXPORT_OPTIONS_PLIST" -exportPath "$ios_stage/export"
  if [ ! -f "$ios_stage/export/MultiSync.ipa" ]; then
    echo "Xcode 未生成预期的 MultiSync.ipa；不会发布旧产物。" >&2; exit 1
  fi
  ditto -x -k "$ios_stage/export/MultiSync.ipa" "$ios_stage/verify"
  ios_signed_app="$ios_stage/verify/Payload/MultiSync.app"
  test -f "$ios_signed_app/embedded.mobileprovision"
  codesign --verify --deep --strict -R='anchor apple generic' "$ios_signed_app"
  cp "$ios_stage/export/MultiSync.ipa" dist/ios/MultiSync-iOS-signed.ipa
  printf '%s\n' '已签名并验证 dist/ios/MultiSync-iOS-signed.ipa。安装范围由所选描述文件决定。'
fi
