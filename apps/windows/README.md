# MultiSync for Windows

原生 WinUI 3 客户端，复用 Rust 传输引擎；不通过 WebView 模拟收发。

## 开发与构建

需要 Windows 10 1809+ / Windows 11，.NET 8 SDK、Visual Studio 2022 的 Windows 应用开发与 C++ 构建工具，以及 stable Rust MSVC 工具链。Windows SDK / XAML 构建工具通过项目 NuGet 依赖恢复。GitHub `windows-latest` 可构建：

```powershell
pwsh -File scripts/build-windows.ps1
```

输出 `dist/MultiSync-Windows-x64.zip`，内含应用、.NET/Windows App SDK 运行库及 `multi_sync_bridge.dll`。完整解压后启动 `MultiSync.Windows.exe`；不能只复制 EXE。此为未签名开发构建。

在 Visual Studio 打开 `MultiSync.Windows.csproj`，选择 x64，先运行 `cargo build --release -p multi-sync-bridge`。默认 Debug 配置可调试 C#；Rust DLL 需要另行启用原生调试并选择保留调试符号的构建。

## 使用

接收端选择本机局域网地址和接收目录，点击“开启接收”。本机自动生成二维码，直接“复制接收码”“分享二维码”或保存 PNG。没有让接收方粘贴邀请的前置步骤。

发送端优先“扫码连接”或导入二维码图片；“从剪贴板粘贴”仅为备用操作。选择文件会在用户私有应用目录生成稳定副本，点击发送后才开始传输。对方需显式接受；双方均保留原件。未完成任务在重启后显示为暂停，继续使用同一持久 journal 恢复。

发送历史和稳定副本位于 `%LOCALAPPDATA%\MultiSync`。默认接收目录为用户 `Downloads\MultiSync`，可更改。只有完整校验并提交成功的收到文件才提供打开和系统分享操作。

摄像头窗口先显示“开启摄像头”，点击后才访问摄像头；取消或识别后释放资源，不录制或上传画面。应用为 unpackaged desktop，使用 Windows 的“允许桌面应用访问摄像头”权限；权限拒绝、硬件占用或无摄像头时可以使用图片识别。

## 验证边界

`ModelChecks` 检查队列重启恢复、传完字节不等于完成、错误信息、损坏历史保留和局域网地址过滤。实际 C ABI、HTTPS、续传和原文件保留由根目录集成测试覆盖。

编译和模型测试不代表摄像头实拍、Windows 系统分享目标、Windows 防火墙、休眠恢复或两台真机 Wi-Fi 已验收。需要在 Windows 真机继续验证这些系统边界。接收目录当前仍需支持同卷硬链接，例如 NTFS。
