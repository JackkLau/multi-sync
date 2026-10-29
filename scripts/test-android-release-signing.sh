#!/bin/sh
# Exercise real Gradle/SDK release signing without any production credentials.
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
umask 077
signing_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/multisync-signing-test.XXXXXX")
trap 'rm -rf "$signing_test_dir"' EXIT HUP INT TERM
export MULTISYNC_ANDROID_KEYSTORE="$signing_test_dir/test.jks"
export MULTISYNC_ANDROID_KEY_ALIAS=multisync-ci-test
MULTISYNC_ANDROID_STORE_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
export MULTISYNC_ANDROID_STORE_PASSWORD
export MULTISYNC_ANDROID_KEY_PASSWORD="$MULTISYNC_ANDROID_STORE_PASSWORD"
keytool -genkeypair -keystore "$MULTISYNC_ANDROID_KEYSTORE" -storetype JKS \
  -storepass:env MULTISYNC_ANDROID_STORE_PASSWORD -keypass:env MULTISYNC_ANDROID_KEY_PASSWORD \
  -alias "$MULTISYNC_ANDROID_KEY_ALIAS" -keyalg RSA -keysize 2048 -validity 2 \
  -dname 'CN=MultiSync CI Test Only, O=MultiSync' -noprompt
keytool -exportcert -keystore "$MULTISYNC_ANDROID_KEYSTORE" \
  -storepass:env MULTISYNC_ANDROID_STORE_PASSWORD -alias "$MULTISYNC_ANDROID_KEY_ALIAS" \
  -file "$signing_test_dir/certificate.der"
signing_test_sha=$(python3 - "$signing_test_dir/certificate.der" <<'PY'
import hashlib
import sys
from pathlib import Path
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)
cd "$project_root/apps/android"
sh ./gradlew --no-daemon -Pmultisync.requireReleaseSigning=true assembleRelease
sh "$project_root/scripts/verify-android-apk.sh" \
  "$project_root/apps/android/app/build/outputs/apk/release/app-release.apk" "$signing_test_sha"
printf '%s\n' 'Disposable-key release signing verified. This test APK is not a distributable release.'
