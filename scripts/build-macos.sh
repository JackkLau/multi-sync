#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
ui_only=false
signed=false
for argument in "$@"; do
  case "$argument" in
    --ui-only) ui_only=true ;;
    --signed) signed=true ;;
    *) echo "用法：sh scripts/build-macos.sh [--ui-only | --signed]" >&2; exit 2 ;;
  esac
done
if [ "$signed" = true ]; then
  if [ "$ui_only" = true ]; then
    echo "正式签名需要完整传输引擎，不能与 --ui-only 一起使用。" >&2; exit 2
  fi
  if [ -z "${MULTISYNC_MACOS_SIGNING_IDENTITY:-}" ] || [ "$MULTISYNC_MACOS_SIGNING_IDENTITY" = - ]; then
    echo "--signed 需要 MULTISYNC_MACOS_SIGNING_IDENTITY 指定钥匙串中已有的 Apple 签名身份。" >&2; exit 1
  fi
  if ! security find-identity -v -p codesigning | grep -Fq -- "$MULTISYNC_MACOS_SIGNING_IDENTITY"; then
    echo "钥匙串中没有指定的有效签名身份；不会降级为 ad-hoc 签名。" >&2; exit 1
  fi
fi
if [ "$ui_only" = false ]; then
  if ! command -v cargo >/dev/null 2>&1; then
    echo "缺少 Rust。安装工具链后重试；只构建界面可加 --ui-only。" >&2
    exit 1
  fi
  cargo build --locked --release -p multi-sync
fi
sh scripts/swift.sh build -c release
app="$project_root/dist/MultiSync.app"
mkdir -p "$app/Contents/MacOS"
cp .build/swift/release/MultiSync "$app/Contents/MacOS/MultiSync"
if [ "$ui_only" = false ]; then cp target/release/multi-sync "$app/Contents/MacOS/multi-sync"; fi
cp apps/macos/Info.plist "$app/Contents/Info.plist"
if [ "$signed" = true ]; then
  macos_sign_stage=$(mktemp -d "$project_root/.build/macos-sign.XXXXXX")
  trap 'rm -rf "$macos_sign_stage"' EXIT HUP INT TERM
  # Hardened Runtime needs camera access for the existing QR scanner.
  cat > "$macos_sign_stage/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.device.camera</key><true/></dict></plist>
PLIST
  # Sign nested executable code first, then seal the outer app bundle.
  codesign --force --sign "$MULTISYNC_MACOS_SIGNING_IDENTITY" --options runtime --timestamp "$app/Contents/MacOS/multi-sync"
  codesign --force --sign "$MULTISYNC_MACOS_SIGNING_IDENTITY" --options runtime --timestamp \
    --entitlements "$macos_sign_stage/entitlements.plist" "$app"
  codesign --verify --deep --strict --all-architectures -R='anchor apple generic' "$app"
  codesign -d --entitlements - --xml "$app" > "$macos_sign_stage/embedded-entitlements.plist"
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.camera' "$macos_sign_stage/embedded-entitlements.plist")" != true ]; then
    echo "签名产物缺少扫码所需的相机 entitlement；不会生成已签名 ZIP。" >&2; exit 1
  fi
  ditto -c -k --keepParent "$app" "$project_root/dist/MultiSync-macOS-signed.zip"
  echo "已签名并验证：dist/MultiSync-macOS-signed.zip（尚未公证）。"
else
  codesign --force --sign - "$app"
  codesign --verify --deep --strict "$app"
fi
echo "已构建：$app"
if [ "$ui_only" = true ]; then echo "仅构建原生界面；收发功能需要另外构建 Rust 引擎。"; fi
