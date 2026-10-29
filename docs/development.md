# 构建与调试

[返回项目首页](../README.md) · [功能与边界](project-status.md) · [CLI 使用](cli.md) · [验证记录](verification.md)

普通使用请先从项目首页下载安装包。以下命令均在仓库根目录执行；平台 SDK、IDE 和原生工具链需在对应主机上安装。

## 获取源码

```sh
git clone https://github.com/JackkLau/multi-sync.git
cd multi-sync
```

预览包的源码提交见首页下载区。复现指定预览时，请先检出对应提交，再执行构建；不要将尚未合并分支的产物视为默认分支构建。

## 各平台构建入口

| 平台 | 构建主机与工具 | 入口 |
| --- | --- | --- |
| Android | JDK 17、Android SDK/NDK、Rust、cargo-ndk | `sh scripts/build-android.sh`；[Android 说明](../apps/android/README.md) |
| iPhone / iPad | macOS、完整 Xcode、Rust、XcodeGen | `sh scripts/build-ios.sh --test`；[iOS 说明](../apps/ios/README.md) |
| Windows x64 | Windows、.NET 8 SDK、Visual Studio C++/Windows 工具、Rust MSVC | `pwsh -File scripts/build-windows.ps1`；[Windows 说明](../apps/windows/README.md) |
| macOS | macOS 13+、Xcode/Swift、Rust | `sh scripts/build-macos.sh` |

各平台安装包与签名说明见[项目首页](../README.md#下载与安装)。

## Android Studio 打开与调试

1. 在 Android Studio 选择 **Open**，打开仓库下的 **`apps/android`**，不要把 Rust 仓库根目录当作 Android 工程。
2. Gradle JDK 选 JDK 17；SDK Manager 安装 Android SDK 35、Build Tools 35.0.0 和 NDK 28.2.13676358。项目固定 Gradle 8.11.1 / AGP 8.9.2 / Kotlin 2.1.20。
3. 安装 stable Rust 与 `cargo-ndk`，在仓库根目录运行：

   ```sh
   rustup target add aarch64-linux-android x86_64-linux-android
   cargo install cargo-ndk --version 4.0.0 --locked
   sh scripts/build-android.sh
   ```

4. 等待 Gradle Sync，选择 `app` / `debug`，连接开启 USB 调试的 Android 8.0+ arm64 手机，或启动 x86_64 模拟器，点击 **Debug**。Kotlin 入口是 `MainActivity.kt`，业务状态在 `TransferModel.kt`。
5. 局域网联调优先使用两台真实设备接入同一 Wi-Fi；模拟器的虚拟地址通常不能直接作为其他设备可达的接收地址。二维码生成、复制和图片识别可以先在模拟器调试。

缺少 Rust `.so` 时工程会明确报错，避免生成只有界面却无法收发的 APK。修改 Rust 后重新执行构建脚本；仅改 Kotlin 时可直接从 Android Studio 构建。详细说明见 [Android README](../apps/android/README.md) 和 [iOS README](../apps/ios/README.md)。

## 先运行 macOS 界面

需要 macOS 13+ 和 Xcode/Swift 工具链，无外部 Swift 依赖。

```sh
sh scripts/dev-macos.sh --ui-only
```

此命令构建并打开 `dist/MultiSync.app`，开发数据存放在项目的 `.local/macos`。
缺少 Rust 引擎时，界面会明确提示“传输引擎尚未构建”并禁用收发，不模拟传输。

## macOS 完整构建与共享引擎验证

需要 stable Rust/Cargo 和可访问 crates.io 的网络。仓库固定了 CI 实际构建通过的 Cargo.lock，构建产物也保留对应锁文件。

```sh
sh scripts/verify.sh
sh scripts/build-macos.sh
open dist/MultiSync.app
```

完整构建会把 Rust 引擎放入 app bundle。应用仅做本机 ad-hoc 签名，未做开发者签名或公证。
也可在界面中选择已经构建好的 `target/debug/multi-sync`。

独立检查：

```sh
sh scripts/swift.sh test
cargo test --locked --workspace
cargo build --locked -p multi-sync
python3 tests/lan_e2e.py
```

