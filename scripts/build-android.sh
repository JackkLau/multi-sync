#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
android_build_mode=debug
case "${1:-}" in
  "") ;;
  --release) android_build_mode=release ;;
  --release-unsigned) android_build_mode=unsigned ;;
  *) echo "用法：sh scripts/build-android.sh [--release | --release-unsigned]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "只能选择一个 Android 构建模式。" >&2; exit 2
fi
if [ "$android_build_mode" = release ]; then
  # Check credentials before compiling Rust. Passwords are never command-line args.
  (cd apps/android && sh ./gradlew --no-daemon checkReleaseSigning)
fi
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
CARGO_PROFILE_RELEASE_DEBUG=1 cargo ndk -t arm64-v8a -t x86_64 --platform 26 -o apps/android/app/src/main/jniLibs build --locked --release -p multi-sync-bridge --features android-jni
cd apps/android
case "$android_build_mode" in
  debug)
    sh ./gradlew --no-daemon testDebugUnitTest assembleDebug
    printf '%s\n' "Android Debug APK：$project_root/apps/android/app/build/outputs/apk/debug/app-debug.apk"
    ;;
  release)
    sh ./gradlew --no-daemon -Pmultisync.requireReleaseSigning=true testReleaseUnitTest assembleRelease
    sh "$project_root/scripts/verify-android-apk.sh" "$project_root/apps/android/app/build/outputs/apk/release/app-release.apk"
    printf '%s\n' "Android 已签名 Release APK：$project_root/apps/android/app/build/outputs/apk/release/app-release.apk"
    ;;
  unsigned)
    sh ./gradlew --no-daemon -Pmultisync.unsignedRelease=true testReleaseUnitTest assembleRelease
    test -s app/build/outputs/apk/release/app-release-unsigned.apk
    printf '%s\n' "Android 未签名 Release APK（不能直接安装）：$project_root/apps/android/app/build/outputs/apk/release/app-release-unsigned.apk"
    ;;
esac
