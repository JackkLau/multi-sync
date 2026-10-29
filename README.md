# MultiSync

**让不同品牌的手机、平板和电脑，在同一局域网内直接传文件。**

[![Build and test](https://github.com/JackkLau/multi-sync/actions/workflows/build.yml/badge.svg)](https://github.com/JackkLau/multi-sync/actions/workflows/build.yml)

[下载安装](#下载与安装) · [快速上手](#快速上手) · [开发文档](docs/development.md) · [反馈问题](https://github.com/JackkLau/multi-sync/issues)

MultiSync 为 Android、iPhone/iPad、Windows 和 macOS 提供原生客户端。无需注册账号，也无需把文件上传到云端：接收设备展示二维码，发送设备扫码连接，确认后即可传送文件。

> **开发预览**：当前支持局域网文件传送。发送后双方保留独立副本，不传播修改或删除。自动目录同步、远程离线投递和家庭共享仍在规划中；真机扫码与跨设备 Wi-Fi 尚需进一步验收。

## 核心功能

- **跨平台互传**：手机素材传电脑、电脑资料传平板，四类系统使用同一传输协议。
- **扫码即连接**：开启接收后自动生成本机二维码，直接复制接收码或分享二维码；发送端支持相机扫码和图片识别，无需先粘贴才能分享自己的接收码。
- **中断后继续**：保存任务、进度和历史记录，支持暂停、继续与重试；重启后可恢复未完成的任务。
- **接收由你确认**：每份新文件都需接收方确认，扫码只选择目标，不会自动发送或接收。
- **保护文件内容**：HTTPS 加密传输，分块与整文件校验；保留源文件，同名文件不静默覆盖。
- **原生操作体验**：手机与平板自适应布局，使用系统文件选择器，接收后可打开、定位或导出文件。

## 下载与安装

目前通过 **GitHub Actions 提供开发预览包**，尚未发布正式 Release 或应用商店版本。下列下载对应 [已通过全部 6 项任务的构建 #10](https://github.com/JackkLau/multi-sync/actions/runs/40911292441)，源码提交为 [`7a7972e`](https://github.com/JackkLau/multi-sync/commit/7a7972edbf824b230163a5dcfec57ab414eca25c)。

| 平台 | 系统与架构 | 下载 | 安装方式 |
| --- | --- | --- | --- |
| Android 手机 / 平板 | Android 8.0+；arm64-v8a / x86_64 | [Android APK](https://github.com/JackkLau/multi-sync/actions/runs/40911292441/artifacts/12913409725) | 解压下载包后安装 `app-debug.apk`，为调试签名版本 |
| iPhone / iPad | iOS / iPadOS 16+ | [iOS 构建包](https://github.com/JackkLau/multi-sync/actions/runs/40911292441/artifacts/12914711968) | 含未签名 IPA 和模拟器应用；真机需自行签名，见 [iOS 指南](apps/ios/README.md) |
| Windows | Windows 10 1809+ / Windows 11；x64 | [Windows 应用包](https://github.com/JackkLau/multi-sync/actions/runs/40911292441/artifacts/12915065700) | 完整解压内含的 `MultiSync-Windows-x64.zip`，运行 `MultiSync.Windows.exe` |
| macOS | macOS 13+；Apple Silicon | [macOS 应用包](https://github.com/JackkLau/multi-sync/actions/runs/40911292441/artifacts/12913663241) | 解压内含的 `MultiSync-macOS.zip`，将 `MultiSync.app` 移入“应用程序” |

下载 Actions 产物需要登录 GitHub，产物有保留期限。链接失效时，请到 [Build and test](https://github.com/JackkLau/multi-sync/actions/workflows/build.yml) 选择一次成功运行，在页面底部的 **Artifacts** 中下载对应平台包，或[从源码构建](docs/development.md)。下载操作见 [GitHub 官方说明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)。

iOS 未签名 IPA **不能直接安装**，模拟器包需匹配模拟器架构。macOS 包仅做 ad-hoc 签名、尚未公证，Windows 包尚未签名；这些都是测试构建。

## 快速上手

1. **连接同一网络**：两台设备接入同一 Wi-Fi、手机热点或路由器，打开 MultiSync；移动设备保持应用在前台。
2. **接收端展示二维码**：进入接收页面，选择本机局域网地址，点击开启接收。本机会自动生成二维码，可直接展示、复制接收码或分享二维码图片。
3. **发送端扫码并选文件**：点击“扫码连接”或导入二维码图片，核对接收目标，选择文件并发送。粘贴已有接收码也是可选方式。
4. **确认并收取文件**：接收端逐份确认；校验完成后即可打开、定位或导出。中断的任务可从任务列表继续。

接收码包含连接凭据，请仅分享给目标设备。相机只在主动扫码时启用，二维码识别在本机完成。

## 使用须知

- **连接不通**：检查两端地址、接收状态和防火墙；默认使用 TCP `53318`。访客 Wi-Fi、AP 隔离或不同网段可能阻止直连，二维码无法绕过网络隔离。目前使用 IPv4，尚无自动设备发现。
- **手机切到后台**：Android、iPhone/iPad 会暂停收发并保留任务；返回应用后手动开启接收或继续发送。
- **长期保存文件**：移动端文件位于应用管理空间，请通过导出或另存保留重要文件；卸载或清除应用数据会删除应用内副本和任务。

完整能力、文件系统要求与安全边界见[功能与实现状态](docs/project-status.md)，测试覆盖范围见[验证记录](docs/verification.md)。

## 文档

| 文档 | 内容 |
| --- | --- |
| [功能与实现状态](docs/project-status.md) | 各端实现清单、扫码流程、当前限制、源码结构和后续计划 |
| [构建与调试](docs/development.md) | Android Studio 打开方式、各平台工具链、构建与验证命令 |
| [Android 发布签名](docs/signing-android.md) / [Apple 与 Windows 签名](docs/signing-platforms.md) | 本地密钥、签名构建、证书要求与产物验证 |
| [CLI 使用](docs/cli.md) | 命令行收发、确认与断点续传 |
| [传输协议](docs/protocol-v1.md) / [原生桥接](docs/native-bridge.md) | HTTPS 协议、恢复规则与 C ABI / JNI 接口 |
| [验证记录](docs/verification.md) | CI 证据、已修复问题与待完成的真机验收 |

## 路线图

- 完成四类系统间的真机网络、扫码和生命周期验收。
- 增加自动发现、设备配对、信任管理与撤销。
- 逐步扩展到选择性目录同步、照片归档、远程投递和家庭共享。

以上为规划方向，当前下载包的能力以[实现状态](docs/project-status.md)为准。

## 参与贡献

欢迎通过 [Issues](https://github.com/JackkLau/multi-sync/issues) 提交问题和建议，或通过 Pull Request 改进项目。报告问题时，请附上系统版本、应用提交或构建编号、网络环境、复现步骤及已脱敏的错误信息；不要上传接收码、私钥或个人文件。开发前请阅读[构建与调试](docs/development.md)及相关协议文档。

## 许可证

项目尚未选定开源许可证，当前 `Cargo.toml` 标记为 `UNLICENSED`。第三方依赖及随附工具遵循各自许可证。
