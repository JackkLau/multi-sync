#!/bin/sh
# Validate an already-signed release APK without modifying it.
set -eu
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "用法：sh scripts/verify-android-apk.sh APK [预期证书SHA256]" >&2; exit 2
fi
android_apk=$1
android_expected_sha=${2:-${MULTISYNC_ANDROID_CERT_SHA256:-}}
android_sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
if [ -z "$android_sdk" ] && [ -d "$HOME/Library/Android/sdk" ]; then
  android_sdk="$HOME/Library/Android/sdk"
fi
if [ -z "$android_sdk" ]; then
  echo "请设置 ANDROID_HOME 指向 Android SDK。" >&2; exit 1
fi
android_tools="$android_sdk/build-tools/${ANDROID_BUILD_TOOLS_VERSION:-35.0.0}"
for android_tool in apksigner zipalign aapt; do
  if [ ! -x "$android_tools/$android_tool" ]; then
    echo "缺少 Android Build Tools 工具：$android_tool。请安装 build-tools 35.0.0 或设置 ANDROID_BUILD_TOOLS_VERSION。" >&2; exit 1
  fi
done
if [ ! -s "$android_apk" ]; then
  echo "APK 不存在或为空。" >&2; exit 1
fi
android_report_dir=$(mktemp -d "${TMPDIR:-/tmp}/multisync-apk-verify.XXXXXX")
trap 'rm -rf "$android_report_dir"' EXIT HUP INT TERM
"$android_tools/apksigner" verify --verbose --print-certs "$android_apk" > "$android_report_dir/signature.txt"
"$android_tools/zipalign" -c -P 16 4 "$android_apk"
"$android_tools/aapt" dump badging "$android_apk" > "$android_report_dir/manifest.txt"
python3 - "$android_apk" "$android_report_dir" "$android_expected_sha" <<'PY'
import re
import sys
import zipfile
from pathlib import Path

apk, reports, expected = sys.argv[1:]
signature = (Path(reports) / 'signature.txt').read_text()
manifest = (Path(reports) / 'manifest.txt').read_text()

def require(condition, message):
    if not condition:
        raise SystemExit(message)

require("package: name='local.multisync'" in manifest, 'APK 包名不是 local.multisync。')
require('application-debuggable' not in manifest, '拒绝将可调试 APK 标记为发布包。')
require(re.search(r'Verified using v[23](?:\.1)? scheme[^\n]*: true', signature), 'APK 缺少通过验证的 v2/v3 签名。')
require(not re.search(r'certificate DN:.*CN\s*=\s*Android Debug(?:,|\s*$)', signature, re.I | re.M), '拒绝使用 Android Debug 证书作为发布签名。')
digests = re.findall(r'^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F]{64})\s*$', signature, re.M)
require(len(digests) == 1, '需要且仅允许一个发布签名证书。')
fingerprint = digests[0].upper()
if expected:
    expected = expected.replace(':', '').strip().upper()
    require(re.fullmatch(r'[0-9A-F]{64}', expected), '预期证书 SHA-256 格式无效。')
    require(fingerprint == expected, 'APK 签名证书与预期证书不一致。')
with zipfile.ZipFile(apk) as archive:
    for name in ['AndroidManifest.xml', 'classes.dex']:
        require(archive.getinfo(name).file_size > 0, f'APK 缺少有效 {name}。')
    for abi in ['arm64-v8a', 'x86_64']:
        name = f'lib/{abi}/libmulti_sync_bridge.so'
        require(archive.getinfo(name).file_size > 0, f'APK 缺少 {abi} 原生引擎。')
        with archive.open(name) as native:
            require(native.read(4) == b'\x7fELF', f'{abi} 原生引擎不是 ELF 库。')
print('Release APK 验证通过：有效签名、非调试应用、16 KiB ZIP 对齐、双 ABI 原生引擎。')
print('签名证书 SHA-256：' + fingerprint)
PY
