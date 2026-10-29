#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
python3 -m unittest discover -s tests -p 'test_*.py'
if ! command -v cargo >/dev/null 2>&1; then
  echo "无法验证 Rust：cargo 不可用。macOS 检查可单独执行 sh scripts/swift.sh test。" >&2
  exit 1
fi
cargo test --locked --workspace
cargo build --locked -p multi-sync -p multi-sync-bridge
python3 tests/lan_e2e.py
case "$(uname -s)" in
  Darwin) MULTISYNC_LIBRARY=target/debug/libmulti_sync_bridge.dylib python3 tests/bridge_e2e.py ;;
  Linux) MULTISYNC_LIBRARY=target/debug/libmulti_sync_bridge.so python3 tests/bridge_e2e.py ;;
esac
if [ "$(uname -s)" = Darwin ]; then sh scripts/swift.sh test; fi
