#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
run_tests=false
case "${1:-}" in
  --test) run_tests=true ;;
  "") ;;
  *) echo "用法：sh scripts/build-ios.sh [--test]" >&2; exit 2 ;;
esac
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
SDKROOT="$ios_device_sdk" IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo build -p multi-sync-bridge --release --target aarch64-apple-ios
SDKROOT="$ios_simulator_sdk" IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo build -p multi-sync-bridge --release --target "$simulator_target"
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
