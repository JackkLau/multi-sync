# 验证记录

日期：2026-10-29（Asia/Hong_Kong）。范围为四类操作系统的原生局域网文件收发客户端、共享引擎和二维码连接。构建/回环测试与物理设备验收分别记录。

功能提交：[PR #2](https://github.com/JackkLau/multi-sync/pull/2)。当前移动端/Windows 完整构建正在运行，最终以该 PR 最新提交的检查为准，不能用旧提交的绿灯替代新提交结果。

## 需求与证据

| 需求或风险 | 可观察行为 | 验证路径 | 当前证据 |
| --- | --- | --- | --- |
| 本机接收码不依赖粘贴 | 开启接收 → 引擎 ready → 本机 QR；复制/原生分享 | 四端 UI 与 ready 事件调用链检查 | 实现已核对；物理设备待验收 |
| 扫描可直接识别目标 | 相机/图片读取完整 msync1 邀请，验证后仅选择目标 | Swift QR 回读、Android 契约、原生图片选择器 | macOS 回读与原生图片导入通过；其余平台运行见下表 |
| 不自动接收陌生请求 | 新任务 pending，确认前不能上传字节 | Python HTTPS、C ABI、移动端仪器测试 | 桌面共享引擎通过 |
| 中断与重启不丢任务 | 保存 journal/SQLite；暂停后从已确认位置恢复 | bridge_e2e.py、lan_e2e.py | 三类桌面 runner 的 C ABI 通过 |
| 内容与原件保留 | 原文件不删除，内容一致，同名不覆盖，恢复不重复 | 真实 TLS 传输后的字节比较 | 桌面共享引擎通过 |
| Android 可用构建 | APK 包含两种 ABI；模拟器真实 JNI TLS 收发 | GitHub Android 构建与 BridgeSmokeTest | 正在运行 |
| iPhone/iPad 可用构建 | 真机/模拟器链接真实 Rust 库，模拟器执行 HTTPS 测试 | scripts/build-ios.sh --test | 正在运行 |
| Windows 完整应用 | 自包含 WinUI exe + Rust DLL，队列模型测试 | scripts/build-windows.ps1 | 正在运行 |
| 移动端后台边界 | 后台暂停，手动恢复，停机完成前不可重开 | 生命周期与停止状态源码检查 | 已检查；锁屏/强退/物理设备待验收 |

## 已完成的共享引擎与 macOS 验证

来源：[Actions run 40902629361](https://github.com/JackkLau/multi-sync/actions/runs/40902629361)，提交 `27f52a550225f9f09900a1935f6c5277ed2343e0`。这是平台客户端接入前的桥接基线。

- Linux、Windows、macOS 的 Rust 工作区测试及 Release CLI 构建通过。
- 三个平台均加载真实共享库执行 C ABI HTTPS 集成测试，覆盖显式接受、暂停/停止/恢复、2 MiB 文件内容、保留源文件、同名文件保护、完成后的幂等恢复和无效请求。
- Linux、macOS 的真实 CLI HTTPS 集成测试通过，覆盖鉴权、证书、路径限制和重启恢复。
- macOS Swift 测试（含完整邀请二维码回读）、完整应用构建、签名检查、ZIP 打包及上传通过。

## 本地检查

环境：Apple Silicon macOS、Xcode 16.2 / iOS SDK 18.2。终端网络受限，本地没有 Rust/Cargo、dotnet 或所需 Gradle 发行包，因此完整跨平台编译交由 GitHub Actions。

| 检查 | 结果与范围 |
| --- | --- |
| macOS sh scripts/swift.sh build | 成功，包含直接复制/分享二维码界面；未打包 Rust 引擎 |
| iOS App 与 XCTest 全源码 typecheck | 使用真实 iOS SDK 通过；不能替代链接和模拟器运行 |
| Android Kotlin/Compose typecheck | 通过；JourneyApps 扫码依赖使用临时 API 声明，不能代替 Gradle 编译；临时声明未提交 |
| Windows 项目/XAML/manifest XML | 格式检查通过；没有本地 C# 编译证据 |
| plist、Shell、YAML | 结构/语法检查通过 |
| Gradle Wrapper | 官方 v8.11.1 JAR，blob a4b76b9530d66f5e68d973ea569d8e19de379189；ZIP 完整性通过，许可证与来源随源码保存 |
| 事件读取回归 | python3 -m unittest discover -s tests -p 'test_*.py' 通过 |
| UI 合约严格审计 | audit_project.py --mode strict，0 findings；不是可访问性认证 |

先前 macOS 原生窗口检查已完成：图片选择器导入 QR 后自动识别、没有自动发送；扫码窗口初始不启用相机；缺少引擎时禁用收发。物理摄像头对屏扫码尚未验收。

## 修复记录

- 早期 Python TextIO 预读与 select 混用导致事件已在用户缓冲中却误报超时；改为线程读取队列，并保留确定性回归测试。
- axum-server 接收标准监听器前需要 set_nonblocking(true)；补上非阻塞设置及空闲停机测试，解决 macOS 接收循环阻塞。
- iOS 停机改为 stop → poll finished → release，停机期间禁止立即重启/续传，避免端口与任务重入。

## 尚未覆盖的发布条件

- 四类真实设备间 Wi-Fi、热点、访客网络、系统防火墙、相机权限拒绝/撤销，以及手机锁屏/强制退出/省电策略，仍需验收。
- CI 的网络测试为真实 HTTPS 回环，不是两台物理设备间传输；模拟器成功不能替代相机与无线网络测试。
- 未验证 GB 级文件、上万小文件、断电、磁盘满、耗电、吞吐与长期运行；不能作后台无感同步承诺。
- iOS 产物未签名，真机安装需要自己的 Apple 签名；macOS 仅 ad-hoc 签名，Windows 尚无代码签名，Android 为 debug 签名。未发布商店版本。
- 密钥保存在应用状态目录，尚未接入 Keychain/Android Keystore/Windows DPAPI；设备撤销和恢复尚未实现。
- Cargo.lock 当前随 CI 产物保存，仓库尚未锁定 Rust 依赖；发布前需要纳入已验证锁文件。
- mDNS、目录同步、离线云端投递和其他 App 私有数据同步不在本轮范围。
