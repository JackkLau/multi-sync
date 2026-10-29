# MultiSync for iPhone and iPad

原生 SwiftUI 客户端，最低 iOS/iPadOS 16。与 Android、macOS、Windows 使用同一 Rust 引擎和 `msync1:` HTTPS 协议。

## 开发与构建

在 macOS 安装完整 Xcode、Rust stable 和 XcodeGen 后，从仓库根目录运行：

```sh
sh scripts/build-ios.sh --test
open apps/ios/MultiSyncIOS.xcodeproj
```

脚本构建并链接真实 Rust 静态库，生成 Xcode 工程，分别构建设备与模拟器应用，并在可用 iPhone 模拟器上运行 XCTest。CI 使用同一脚本。产物为：

- `dist/ios/MultiSync-iOS-simulator.zip`：适用于构建主机架构的模拟器应用。
- `dist/ios/MultiSync-iOS-unsigned.ipa`：未签名设备包；真机安装必须在 Xcode 选择自己的开发团队并签名，不能直接安装此文件。
- `dist/ios/tests-*.xcresult`：测试结果。

真机调试：在 Xcode 选择 MultiSync scheme、目标 iPhone/iPad，在 Signing & Capabilities 选择你自己的 Team，然后 Run。Rust 库位于 `Native/iphoneos` / `Native/iphonesimulator`，由脚本生成而不提交版本库。

## 使用

1. 接收端保持应用在前台，打开“接收”并点击“开启接收”；二维码由本机引擎自动生成，无需输入或粘贴任何接收码。
2. 可直接让另一台设备扫码，或点击“复制接收码”“分享二维码”。
3. 发送端点击“扫码连接”或识别二维码图片，添加文件并发送。手动粘贴仅为备用入口。
4. 接收端逐份确认接收。完整校验后才显示完成，可打开预览或通过系统分享另存。

源文件只读。发送前将用户选择的文档协调复制到应用私有持久目录，避免云文档撤回或临时授权失效破坏续传。收件位于“文件 → 我的 iPhone/iPad → MultiSync → Inbox”。发送历史与 journal 在应用支持目录保留；重启后任务显示为暂停，继续时复用同一 journal。

切到后台会停止接收并暂停发送；返回前台后需要明确重新开启或继续。iOS 后台永久监听不属于本版本能力。停止接收不会撤销已经分享的持久邀请；每份新文件仍需接收者确认。

相机只在点击“开启摄像头”后启动，取消、识别完成或进入后台时停止。二维码与画面只在本机处理。模拟器不具备真实相机验证能力，摄像头对屏扫码、局域网权限和双机收发须在真机联调。
