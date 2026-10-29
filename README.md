# MultiSync

跨品牌个人设备的文件与数据共享空间。当前实现 **局域网文件传送与四类系统的原生客户端**：Android 手机/平板、iPhone/iPad、Windows、macOS。

首版约束：两端连接同一 Wi-Fi、手机热点或路由器；发送只读源文件，接收创建副本；不传播修改或删除。
这是开发预览；收发、扫码、队列和构建已接入真实传输引擎，物理设备间的网络、摄像头及后台行为仍需验收。目录自动同步、云端投递和家庭共享不在当前版本内。

## 已写入的实现

- Rust 核心：SQLite 任务、人工接受、1 MiB 顺序分块、SHA-256 分块/整文件校验、重启续传、重复请求处理。
- 接收安全：拒绝远程路径与跨平台保留名，临时文件隔离，不静默覆盖同名文件，磁盘空间检查。
- Rust CLI：HTTPS 接收服务、绑定邀请中的自签证书的发送端、持久发送 journal、JSON 行进度事件。
- macOS：SwiftUI 原生发送/接收页面，多文件串行队列、暂停/继续/重试、持久历史、接收确认、Finder 定位；接收二维码、摄像头扫码与二维码图片识别。
- Android：Kotlin + Compose 自适应手机/平板界面，JNI 收发、持久队列、接收确认、扫码/图片识别、文件打开/分享/另存。
- iPhone/iPad：SwiftUI 自适应界面，C ABI 收发、串行队列、文件选择/预览/导出、摄像头与图片扫码。
- Windows：WinUI 3 自包含客户端，C ABI 收发、持久队列、接收确认、摄像头/图片识别、系统文件与二维码分享。
- 各端接收页：开启接收后自动生成本机二维码，可以直接复制接收码或分享二维码，**不需要先粘贴接收码**。
- 测试：核心恢复用例、独立 Python HTTPS/C ABI 集成、Swift QR 回读、Android JNI 模拟器、iOS 模拟器原生引擎测试。

实现存在不等于验证通过。最新证据和限制见 [docs/verification.md](docs/verification.md)。

## 下载和打开工程

GitHub [Actions](https://github.com/JackkLau/multi-sync/actions) 的成功运行底部提供以下构建产物；请查看与最新提交一致的运行。

| 平台 | 产物 | 本地工程与构建入口 |
| --- | --- | --- |
| Android | `MultiSync-Android-debug` 中的 `app-debug.apk` | Android Studio 打开 `apps/android`；`sh scripts/build-android.sh` |
| iPhone / iPad | 未签名 `.ipa`、模拟器 `.app` ZIP、XCTest 结果 | `sh scripts/build-ios.sh --test`；生成后打开 `apps/ios/MultiSyncIOS.xcodeproj` |
| Windows x64 | `MultiSync-Windows-x64.zip`，完整解压后运行 exe | `pwsh -File scripts/build-windows.ps1` |
| macOS | `MultiSync-macOS.zip` | `sh scripts/build-macos.sh` |

Android APK 使用调试签名，可用于开发测试。iOS 真机安装需要自己的 Apple 签名，未签名 IPA 不能直接安装；模拟器 ZIP 仅供匹配架构的 iOS Simulator 使用。macOS 目前仅 ad-hoc 签名。

### Android Studio 打开与调试

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

缺少 Rust `.so` 时工程会明确报错，避免生成只有界面却无法收发的 APK。修改 Rust 后重新执行构建脚本；仅改 Kotlin 时可直接从 Android Studio 构建。详细说明见 [Android README](apps/android/README.md) 和 [iOS README](apps/ios/README.md)。

## 先运行 macOS 界面

需要 macOS 13+ 和 Xcode/Swift 工具链，无外部 Swift 依赖。

```sh
sh scripts/dev-macos.sh --ui-only
```

此命令构建并打开 `dist/MultiSync.app`，开发数据存放在项目的 `.local/macos`。
缺少 Rust 引擎时，界面会明确提示“传输引擎尚未构建”并禁用收发，不模拟传输。

## 完整构建和验证

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
cargo test --workspace
cargo build -p multi-sync
python3 tests/lan_e2e.py
```

## 扫码连接

1. 接收设备打开“接收文件”，选择本机局域网地址，点击“开启接收”；桌面可选择接收目录，移动端使用应用管理目录。
2. 本机自动生成含连接信息与接收凭据的二维码。直接给另一台设备扫描，或点击“复制接收码”“分享二维码”。此步骤不需要输入或粘贴任何内容。
3. 发送设备点击“扫码连接”，对准接收码；也可选择二维码图片。主动粘贴已有接收码只是备用入口。
4. 识别后显示接收目标；选择文件、点击发送，对方逐份确认接收。扫描本身不会发送文件。

相机权限仅在主动选择扫码/开启摄像头时申请。取消、关闭扫码窗口或识别成功都会停止摄像头；画面只在本机处理。
二维码沿用 `msync1:` 邀请格式，不把密钥上传到第三方网站。四类系统使用相同格式；二维码携带接收凭据，不要公开分享。

## 两台电脑通过 CLI 收发

两台设备均先构建 `cargo build -p multi-sync`。以下以 macOS/Linux shell 为例。
接收方把地址替换成本机实际局域网 IPv4 地址：

```sh
target/debug/multi-sync receive --inbox "$PWD/.local/inbox" --advertise 192.168.1.8
```

首个 JSON 事件给出 `ticket`。它是敏感接收邀请，请仅交给指定设备。发送方执行：

```sh
target/debug/multi-sync send --source /absolute/path/photo.jpg --journal "$PWD/.local/outgoing/photo.json"
```

粘贴接收邀请后按 Enter，再按 Ctrl-D 结束输入。接收方在另一终端确认文件：

```sh
target/debug/multi-sync jobs --inbox "$PWD/.local/inbox"
target/debug/multi-sync approve --inbox "$PWD/.local/inbox" --id <任务ID>
# 或 reject 拒绝该任务。
```

Ctrl-C 暂停发送。接收方保持或重新启动服务后，发送方继续同一任务：

```sh
target/debug/multi-sync send --journal "$PWD/.local/outgoing/photo.json"
```

接收目录、身份和 journal 不变时，继续使用同一任务 ID；已完成任务重试不产生第二份副本。
接收方端口默认为 53318；防火墙需允许该应用的局域网连接。本机双进程测试可使用 127.0.0.1。

## 当前边界

- 二维码和手动接收邀请共用同一协议；mDNS、设备级信任/撤销还未实现。
- 暂只支持 IPv4 局域网普通文件。目录递归、文本/链接、系统分享入口随后接入。
- 当前私钥和邀请保存在用户私有状态目录（Unix 0700/0600）；尚未接入 Keychain、Windows DPAPI 等系统安全存储，Windows ACL 也未验证。不要当作生产版凭据管理。
- 接收邀请重启后仍有效；停止监听不会撤销邀请。每个新文件仍需本地确认。
- 接收目录须支持同卷、不覆盖的原子提交：Android/Linux 使用 `renameat2(RENAME_NOREPLACE)`，Apple/Windows 使用硬链接。桌面外置 FAT/exFAT 尚未支持；不支持时明确报错并保留任务。
- 首版保留拒绝/失败任务和临时数据，不自动清理；清理策略与 UI 尚未实现。
- 校验大文件可能较慢。网络请求有超时；若提交结果未知，再次继续会查询真实状态，不能仅凭进度 100% 宣称完成。
- Android、iPhone/iPad 在进入后台时暂停收发并保留任务。回到应用后手动开启接收/继续发送；没有后台常驻或锁屏持续传输承诺。
- 移动端和 Windows 会暂存用户所选文件，避免文件选择授权失效影响恢复；原文件保留。接收文件要长期保存时使用导出/另存。卸载或清除移动端数据会删除应用内副本、身份和任务。
- 不保证休眠传输或源文件变化时自动建立新快照；源文件变化会停止并要求重新发送。
- 没有遥测、账号、云存储、中继和删除同步。

## 结构与下一步

```text
crates/core       文件与任务不变量、SQLite、校验、提交
crates/cli        HTTPS 平台适配、邀请、命令行、进度事件
crates/bridge     移动端与 Windows 的 C ABI / JNI 接口
apps/macos       原生 SwiftUI 工作台和桌面进程适配
apps/android     Kotlin Compose 手机/平板客户端
apps/ios         SwiftUI iPhone/iPad 客户端
apps/windows     WinUI 3 Windows x64 客户端
tests            独立协议集成测试
scripts          构建、启动和验证
docs             协议、实现边界与验证证据
```

macOS 通过子进程 JSON 连接 Rust；移动端和 Windows 使用共享 [C ABI/JNI 合约](docs/native-bridge.md)。平台负责文件授权、二维码、界面和生命周期，传输核心负责检查点、校验及提交。
GitHub Actions 在 PR、master 提交和手动触发时构建四类系统，Android 与 iOS 分别运行模拟器引擎测试；桌面执行真实 HTTPS 集成测试。
客户端主实现已合并，见 [PR #2](https://github.com/JackkLau/multi-sync/pull/2)；平台兼容修复与最新构建请查看 Actions。下一关口是四类真实设备间的局域网、摄像头和系统生命周期验收，再开展 mDNS/设备配对与目录同步。
