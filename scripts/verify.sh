#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
if ! command -v cargo >/dev/null 2>&1; then
  echo "无法验证 Rust：cargo 不可用。macOS 检查可单独执行 sh scripts/swift.sh test。" >&2
  exit 1
fi
cargo test --workspace
cargo build -p multi-sync
python3 tests/lan_e2e.py
if [ "$(uname -s)" = Darwin ]; then sh scripts/swift.sh test; fi
