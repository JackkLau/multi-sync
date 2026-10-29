# 验证记录

日期：2026-10-29（Asia/Hong_Kong）。当前范围为 Rust 传输引擎、macOS 原生客户端、接收二维码与扫码识别，不代表六类设备全部验收。

代码与后续构建结果：[PR #1](https://github.com/JackkLau/multi-sync/pull/1)。每次代码更新均重新执行 Linux、Windows 和 macOS 构建；以 PR 对应提交的检查结果为准。

## 首次跨平台构建证据

来源：[Actions run 40798013044](https://github.com/JackkLau/multi-sync/actions/runs/40798013044)，源提交 `29694e6d17d8a951753145c843f9a893200dbe00`。下表记录该次运行，不用旧结果替代后续提交的检查。

| 验收项 | 直接证据 | 结果 |
| --- | --- | --- |
| Rust 核心与 CLI | Linux、macOS `cargo +stable test --workspace --release` | 各 9 个测试通过 |
| Windows Rust 核心与 CLI | 同一命令 | 8 个测试通过；Unix 符号链接测试不适用 |
| Windows / Linux Release CLI | `cargo +stable build --release -p multi-sync` | 构建成功、产物已上传 |
| macOS Swift 测试 | `sh scripts/swift.sh test` | 11 个 XCTest 通过，其中 4 个二维码用例 |
| 完整 macOS 应用编译 | `sh scripts/build-macos.sh` | SwiftUI 与 Rust 引擎均构建并打入 app |
| Linux 真实 HTTPS 集成 | `python3 tests/lan_e2e.py` | 3 个用例通过：重启续传、确认/鉴权/证书/路径限制、真实发送器与幂等 |
| macOS 真实 HTTPS 集成 | 同上 | 前 2 个通过；发送器事件读取超时，原因与修复见下文 |

macOS 首次运行在集成测试处停止，未执行后续签名检查、ZIP 打包和产物上传。修复提交仍保留这些步骤，不能仅以编译成功认定整条构建通过。

## 已定位并修复的问题

集成测试原先先对 stdout 调用 `select()`，再用 Python TextIO `readline()`。一次底层读取可能预取多条 JSON 行；第二条已经在 TextIO 缓冲中，但操作系统管道没有新字节，导致误报超时。

已在本地确定性复现：子进程一次写入两条事件后等待输入，旧读取器在第二条超时；随后直接 `readline()` 能读到第二条。修复为独立线程逐行读取并放入队列，消费者在队列上等待。没有延长超时，也没有跳过真实发送测试。

回归命令 `python3 -m unittest discover -s tests -p 'test_*.py'` 本地通过，覆盖连续事件、真正无事件时的超时、EOF 和读取线程收尾；该命令也已加入三个 CI 平台和 `scripts/verify.sh`。修复后的完整网络测试结果见 PR 最新检查。

## 本地原生应用验证

环境：Apple Silicon macOS，Xcode Swift 6.0.3。`sh scripts/build-macos.sh --ui-only` 成功；原生窗口实际启动。

| 用户行为或风险 | 证据 | 结果 |
| --- | --- | --- |
| 完整邀请编码与回读 | CI 将包含约 400 字节证书和密钥的邀请生成 QR，再识别并逐字比较 | 通过 |
| 无效/公网邀请、多接收码 | XCTest 负例 | 拒绝无效和公网邀请；不同邀请不静默选取 |
| 二维码图片导入 | 在实际 app 的原生文件选择器中导入生成的 PNG | 自动填入邀请，并显示成功提示；没有自动发送 |
| 摄像头启动边界 | 打开扫码 Sheet 并检查实际控件 | 摄像头保持未开启，提供“开启摄像头”和“取消”；取消返回发送页 |
| 缺少引擎时的行为 | 本地 ui-only app | 明确提示，收发禁用，无模拟成功 |
| UI 合约 | `audit_project.py <project> --mode strict` | 0 findings；不是完整可访问性认证 |
| 应用配置 | `plutil -lint apps/macos/Info.plist` | 通过，包含摄像头用途说明 |

本地受限终端运行二维码回读测试仍失败：Vision 无法创建像素缓冲，Core Image 无法检出特征。同一 PNG 在实际 GUI 中成功识别，同一源码在 GitHub macOS runner 的 11 个 XCTest 全部通过。因此本地终端结果保留为环境限制，不把它改成跳过或宽松断言。

## 仍需验证的边界

- 尚未进行物理摄像头对屏扫码、摄像头拒绝/撤销权限、无摄像头真机的完整流程测试。当前只有识别器与窗口生命周期的证据。
- 网络集成测试是同一 runner 的真实 HTTPS 回环传输，不是两台设备的 Wi-Fi、防火墙或热点测试；Windows 当前只运行 Rust/事件读取测试和 CLI 构建。
- 未验证 GB 级文件、上万小文件、锁屏/休眠、断电、磁盘满、耗电及吞吐；不能承诺所有后台场景无感恢复。
- 应用仅 ad-hoc 签名，没有 Apple 开发者签名、公证或商店发布。
- CI 生成的 Cargo.lock 随产物保存；本地终端 DNS 受限，无法取回产物以固定仓库依赖。后续发布应先将已验证的锁文件纳入源码。
- 本地无 Rust/Cargo，Rust 编译证据来自 CI；本地 `.git` 写入被环境拒绝，代码通过已连接 GitHub API 提交。本地工作区文件仍保留，Git 元数据未同步。
- 官方 DESIGN.md lint 因 npm 离线缓存缺失未运行；VoiceOver 和最小窗口尺寸仍需完整审计。
- Android、iOS/iPadOS、Windows 原生 UI、mDNS、设备撤销、移动端后台和系统安全存储尚未实现。
