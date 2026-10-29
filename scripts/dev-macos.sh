#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
sh scripts/build-macos.sh "$@"
export MULTISYNC_HOME="$project_root/.local/macos"
exec "$project_root/dist/MultiSync.app/Contents/MacOS/MultiSync"
