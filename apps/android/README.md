# Android 手机 / 平板

原生 Kotlin + Jetpack Compose 客户端；与桌面、iPhone/iPad 共用 Rust 引擎及同一接收码协议。

## 构建

依赖 JDK 17、Android SDK platform 35 / build-tools 35.0.0、NDK 28 或更新版、stable Rust 和 cargo-ndk。

```sh
rustup target add aarch64-linux-android x86_64-linux-android
cargo install cargo-ndk --locked
sh scripts/build-android.sh
```

APK：`apps/android/app/build/outputs/apk/debug/app-debug.apk`。包含 arm64-v8a 真机及 x86_64 模拟器库。此 APK 使用 debug 签名。

在 Android Studio 中打开 **apps/android**，等待 Gradle Sync。先运行上述脚本生成 JNI 库，再选择 app / debug、连接开启 USB 调试的手机，点击 Debug。Kotlin 层可直接设置断点；脚本同时保留 Rust 符号且 APK 不剥离 JNI 符号，Rust 调试需在 Android Studio 配置 LLDB，优化代码可能存在行号跳转。

## 操作

- 接收页选择本机局域网地址，点“开启接收，生成接收码”。无需粘贴任何内容，即可展示二维码、复制接收码或分享二维码图片。
- 发送页“扫码连接”会按操作申请摄像头权限；可从图片识别，或主动使用剪贴板作为备用入口。
- 文件选择器仅授权所选内容；发送前暂存到 app 私有目录，原文件不删除。准备好后逐份点击发送。
- 收件人逐份接受或拒绝。已完成的接收文件支持打开、分享和另存。
- 手机/平板使用自适应布局；大屏显示侧边导航。
- 后台时会暂停收发；返回后可继续已有发送任务。再次开启接收仍使用同一私有身份与端口。没有后台无限保活承诺。

卸载/清除应用数据会删除应用内副本、身份和恢复记录。需要长期保存的接收文件请使用“另存为”。不自动删除任何用户源文件。暂存文件与失败任务不自动清理。
