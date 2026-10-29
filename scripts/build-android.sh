#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
if ! command -v cargo >/dev/null 2>&1; then
  echo "缺少 Rust/Cargo。请安装 stable Rust 工具链。" >&2; exit 1
fi
if ! cargo ndk --version >/dev/null 2>&1; then
  echo "缺少 cargo-ndk。请先运行 cargo install cargo-ndk --locked。" >&2; exit 1
fi
if [ -z "${ANDROID_NDK_HOME:-}" ] && [ -n "${ANDROID_NDK_ROOT:-}" ]; then
  ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"; export ANDROID_NDK_HOME
fi
if [ -n "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"; export ANDROID_NDK_ROOT
fi
CARGO_PROFILE_RELEASE_DEBUG=1 cargo ndk -t arm64-v8a -t x86_64 --platform 26 -o apps/android/app/src/main/jniLibs build --release -p multi-sync-bridge --features android-jni
cd apps/android
sh ./gradlew --no-daemon testDebugUnitTest assembleDebug
printf '%s\n' "Android APK：$project_root/apps/android/app/build/outputs/apk/debug/app-debug.apk"
