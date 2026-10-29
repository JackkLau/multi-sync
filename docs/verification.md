# 验证记录

二维码更新：已加入生成、摄像头扫码、图片识别和完整邀请回读测试，并配置 GitHub Actions。当前本地受限终端的图像识别测试仍失败（Vision 像素缓冲创建失败，Core Image 未检出特征），正在通过实际应用及 CI 定位；不能据此声明二维码回读通过。
本地 `.git/index.lock` 写入被环境拒绝，GitHub 提交改走已连接仓库 API。

以下为首批实现的历史验证记录，更新后的结果将在构建完成后补充。

日期：2026-10-29（Asia/Hong_Kong）。环境：Apple Silicon macOS，Xcode Swift 6.0.3；无 Rust/Cargo。

## 已确认

| 验收项 | 新鲜证据 | 结果 |
| --- | --- | --- |
| Swift 原生客户端编译 | `sh scripts/swift.sh test` | exit 0，包含应用和测试目标编译 |
| 队列恢复、错误状态、邀请校验、进程收尾/暂停 | 同上 | 7 个 XCTest，0 失败 |
| Release app 打包 | `sh scripts/build-macos.sh --ui-only` | exit 0，生成 dist/MultiSync.app，arm64 |
| 本机 ad-hoc 签名完整性 | `codesign --verify --deep --strict dist/MultiSync.app` | exit 0；不代表公证或发布签名 |
| 原生窗口实际启动 | 通过系统应用界面打开 MultiSync.app | 发送页与接收页均可见 |
| 文件选择与移除 | 原生 NSOpenPanel 选择项目 README.md，再从待发送列表移除 | 文件仍存在；未进行任何网络发送 |
| 缺少引擎的行为 | 实际检查两个页面的辅助功能树及窗口截图 | 明确显示未构建；发送和开启接收均禁用 |
| UI 合约静态检查 | `audit_project.py <project> --mode strict` | exit 0，0 findings；不等于可访问性全量认证 |
| Rust 语法树 | 使用本机编辑器已安装的 Tree-sitter Rust grammar 解析 crates 下所有 .rs | 7 文件无语法错误；**不是编译或类型检查** |
| 脚本/配置格式 | Python AST、`sh -n`、`plutil -lint` | 通过 |

Swift 的进程测试使用明确的测试 shell fixture，只证明事件适配、退出与暂停，不证明 Rust 引擎或网络传输。
最初 Swift 编译遇到默认 module cache 写权限问题，脚本现将缓存放在项目 `.build`；重新运行通过。
受限终端直接启动 GUI 曾返回 134；随后通过系统应用界面成功启动。未将该终端结果视作 GUI 验证通过。

## 尚未验证／阻塞

- `cargo`、`rustc` 不可用。终端访问 `static.rust-lang.org` 和 `index.crates.io` 均为 curl exit 6（无法解析域名）。没有绕开环境网络限制，也没有安装全局工具。
- Rust 依赖解析、编译、9 个 Rust 测试、HTTPS 端到端测试均未运行。Cargo.lock 尚未生成，跨平台编译兼容性未确认。
- `tests/lan_e2e.py` 需要真实 Rust 二进制，缺少时明确失败，不用 mock server 冒充成功。它覆盖接收确认、TLS 错证书、鉴权失败、路径穿越、重启续传、幂等与源文件保留。
- 官方 DESIGN.md lint 在本地 npm 缓存缺失，离线运行返回 ENOTCACHED。已运行项目 UI 合约静态检查，但不能替代官方 lint。
- 未验证两台真机、GB 级文件、后台/锁屏/休眠、断电、磁盘满、性能与耗电。
- 未进行 VoiceOver 完整审计、最小窗口尺寸的全流程检查；当前仅做默认窗口和原生文件选择的视觉/语义检查。
- Android、iOS/iPadOS、Windows 原生客户端、mDNS、二维码、移动端后台、系统安全存储尚未实现。

## 环境可用后的首个执行关口

```sh
cargo test --workspace
cargo build -p multi-sync
python3 tests/lan_e2e.py
sh scripts/build-macos.sh
```

先修复这四步暴露的问题并保存 Cargo.lock，再进行两台真实设备的局域网联调。当前不能宣称“跨平台可靠传输已经验收完成”。
