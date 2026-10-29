#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"
swift "$@" --package-path apps/macos --scratch-path .build/swift --disable-sandbox \
  --cache-path .build/swift-cache --config-path .build/swift-config --security-path .build/swift-security
