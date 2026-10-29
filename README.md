# MultiSync

跨品牌个人设备的文件与数据共享空间。当前实现第一个开发切片：**局域网文件传送 + 原生 macOS 工作台**。

首版约束：两端连接同一 Wi-Fi、手机热点或路由器；发送只读源文件，接收创建副本；不传播修改或删除。
这是开发预览，还不是六类设备可交付版本。Android、iOS/iPadOS、Windows 客户端尚未实现。

## 已写入的实现

- Rust 核心：SQLite 任务、人工接受、1 MiB 顺序分块、SHA-256 分块/整文件校验、重启续传、重复请求处理。
- 接收安全：拒绝远程路径与跨平台保留名，临时文件隔离，不静默覆盖同名文件，磁盘空间检查。
- Rust CLI：HTTPS 接收服务、绑定邀请中的自签证书的发送端、持久发送 journal、JSON 行进度事件。
- macOS：SwiftUI 原生发送/接收页面，多文件串行队列、暂停/继续/重试、持久历史、接收确认、Finder 定位；接收二维码、摄像头扫码与二维码图片识别。
- 测试：核心恢复用例、独立 Python HTTPS 集成用例、Swift 队列/状态/进程适配测试。

实现存在不等于验证通过。最新证据和限制见 [docs/verification.md](docs/verification.md)。

## 先运行 macOS 界面

需要 macOS 13+ 和 Xcode/Swift 工具链，无外部 Swift 依赖。

```sh
sh scripts/dev-macos.sh --ui-only
```

此命令构建并打开 `dist/MultiSync.app`，开发数据存放在项目的 `.local/macos`。
缺少 Rust 引擎时，界面会明确提示“传输引擎尚未构建”并禁用收发，不模拟传输。

## 完整构建和验证

需要 stable Rust/Cargo 和可访问 crates.io 的网络。CI 已成功解析和编译依赖，并将生成的 Cargo.lock 随构建产物保存；仓库尚未固定依赖锁，复现对应构建时请使用产物内的 Cargo.lock。

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

1. 接收设备打开“接收文件”，选择接收目录和本机局域网地址，点击“开启接收”。
2. 接收页显示包含完整连接信息和接收密钥的二维码。
3. 发送设备打开“发送文件 → 扫码识别 → 开启摄像头”，对准接收码；也可选择“从二维码图片识别…”。
4. 识别结果自动填入邀请框。扫码不会自动发送文件；选择文件、点击发送后，接收方仍需确认每份文件。

相机权限仅在点击“开启摄像头”时申请。取消、关闭扫码窗口或识别成功都会停止摄像头；画面只在本机处理。
二维码沿用 `msync1:` 邀请格式，不把密钥上传到第三方网站。当前扫码客户端为 macOS；手机原生客户端尚未实现。

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
- 接收目录须支持同卷硬链接（如 APFS/NTFS）。暂不支持 FAT/exFAT；不支持时提交会明确报错并保留任务。
- 首版保留拒绝/失败任务和临时数据，不自动清理；清理策略与 UI 尚未实现。
- 校验大文件可能较慢。网络请求有超时；若提交结果未知，再次继续会查询真实状态，不能仅凭进度 100% 宣称完成。
- 不保证后台常驻、休眠传输、源文件变化时自动建立新快照；源文件变化会停止并要求重新发送。
- 没有遥测、账号、云存储、中继和删除同步。

## 结构与下一步

```text
crates/core       文件与任务不变量、SQLite、校验、提交
crates/cli        HTTPS 平台适配、邀请、命令行、进度事件
apps/macos       原生 SwiftUI 工作台和桌面进程适配
tests            独立协议集成测试
scripts          构建、启动和验证
docs             协议、实现边界与验证证据
```

桌面阶段以子进程 JSON 连接 Swift 与 Rust，避免先引入未验证的 FFI；移动端接入时为 `core` 增加 UniFFI/C ABI，平台负责生命周期与权限。
GitHub Actions 在 PR 和 master 提交时运行 Linux/Windows Rust 构建，以及 macOS 完整应用构建、Swift 二维码回读测试和真实 HTTPS 集成测试，生成 CLI 与应用构建产物。
构建产物和最新检查结果见 [GitHub Actions](https://github.com/JackkLau/multi-sync/actions)；当前功能提交见 [PR #1](https://github.com/JackkLau/multi-sync/pull/1)。下一关口是两台真实设备的局域网与摄像头联调，然后接入 Android、iOS、Windows 原生客户端以及 mDNS/设备配对。
