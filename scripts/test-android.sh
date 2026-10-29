#!/bin/sh
set -u
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
cd "$project_root/apps/android" || exit 1
# The emulator action runs each input line in a separate shell. Keep the test's
# exit status and diagnostic collection in this script's single shell process.
test_status=0
sh ./gradlew --no-daemon connectedDebugAndroidTest || test_status=$?
adb logcat -d -s MultiSyncSmoke:I AndroidRuntime:E '*:S' || true
exit "$test_status"
