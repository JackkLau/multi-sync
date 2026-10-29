#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
ui_only=false
case "${1:-}" in
  --ui-only) ui_only=true ;;
  "") ;;
  *) echo "用法：sh scripts/build-macos.sh [--ui-only]" >&2; exit 2 ;;
esac
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
codesign --force --sign - "$app"
echo "已构建：$app"
if [ "$ui_only" = true ]; then echo "仅构建原生界面；收发功能需要另外构建 Rust 引擎。"; fi
