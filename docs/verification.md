# 验证记录

日期：2026-10-29～30（Asia/Hong_Kong）。范围为四类操作系统的原生局域网文件收发客户端、共享引擎和二维码连接。构建/回环测试与物理设备验收分别记录。

客户端主实现已合并：[PR #2](https://github.com/JackkLau/multi-sync/pull/2)。后续平台兼容修复的完整结果见 [Actions](https://github.com/JackkLau/multi-sync/actions)。各项证据均标明对应运行，不能用旧提交的绿灯替代新提交结果。

## 需求与证据

最新已确认的应用构建基线为提交 `7a7972edbf824b230163a5dcfec57ab414eca25c` 的 [run 40911292441（#10）](https://github.com/JackkLau/multi-sync/actions/runs/40911292441)。六项任务全部成功：Linux/Windows Rust、macOS 应用与二维码测试、Windows 原生应用、Android APK 与真实 JNI HTTPS 模拟器测试、iPhone/iPad 构建与 5 项 XCTest。四端应用包均已上传，产物关联的源码提交一致。下表及后文保留此前运行和修复经过，不能将早期失败视为此基线仍未解决的问题。

| 需求或风险 | 可观察行为 | 验证路径 | 当前证据 |
| --- | --- | --- | --- |
| 本机接收码不依赖粘贴 | 开启接收 → 引擎 ready → 本机 QR；复制/原生分享 | 四端 UI 与 ready 事件调用链检查 | 实现已核对；物理设备待验收 |
| 扫描可直接识别目标 | 相机/图片读取完整 msync1 邀请，验证后仅选择目标 | Swift QR 回读、Android 契约、原生图片选择器 | macOS 回读与原生图片导入通过；其余平台运行见下表 |
| 不自动接收陌生请求 | 新任务 pending，确认前不能上传字节 | Python HTTPS、C ABI、移动端仪器测试 | 桌面共享引擎通过 |
| 中断与重启不丢任务 | 保存 journal/SQLite；暂停后从已确认位置恢复 | bridge_e2e.py、lan_e2e.py | 三类桌面 runner 的 C ABI 通过 |
| 内容与原件保留 | 原文件不删除，内容一致，同名不覆盖，恢复不重复 | 真实 TLS 传输后的字节比较 | 桌面共享引擎通过 |
| Android 可用构建 | APK 包含两种 ABI；模拟器真实 JNI TLS 收发 | GitHub Android 构建与 BridgeSmokeTest | run 40908569718：APK/单元测试与 1 个真实 JNI 测试通过；日志脚本收尾出错已修复，完整流水线见最新 CI |
| iPhone/iPad 可用构建 | 真机/模拟器链接真实 Rust 库，模拟器执行 HTTPS 测试 | scripts/build-ios.sh --test | run 40908569718：5 个测试通过、产物上传 |
| Windows 完整应用 | 自包含 WinUI exe + Rust DLL，队列模型测试 | scripts/build-windows.ps1 | run 40908569718 通过并上传自包含 ZIP |
| 移动端后台边界 | 后台暂停，手动恢复，停机完成前不可重开 | 生命周期与停止状态源码检查 | 已检查；锁屏/强退/物理设备待验收 |

## 已完成的共享引擎与 macOS 验证

来源：[Actions run 40902629361](https://github.com/JackkLau/multi-sync/actions/runs/40902629361)，提交 `27f52a550225f9f09900a1935f6c5277ed2343e0`。这是平台客户端接入前的桥接基线。

- Linux、Windows、macOS 的 Rust 工作区测试及 Release CLI 构建通过。
- 三个平台均加载真实共享库执行 C ABI HTTPS 集成测试，覆盖显式接受、暂停/停止/恢复、2 MiB 文件内容、保留源文件、同名文件保护、完成后的幂等恢复和无效请求。
- Linux、macOS 的真实 CLI HTTPS 集成测试通过，覆盖鉴权、证书、路径限制和重启恢复。
- macOS Swift 测试（含完整邀请二维码回读）、完整应用构建、签名检查、ZIP 打包及上传通过。

原子提交修复提交 `3aee29726946e9c27fc8040c702c85cd3a68af3d` 的 [run 40908569718](https://github.com/JackkLau/multi-sync/actions/runs/40908569718) 中，Linux/Windows/macOS 的工作区、C ABI、CLI 集成和原生应用检查通过；iOS 5 个测试通过，Android APK、JVM 单元测试和真实 JNI 仪器测试通过。Android job 仅在成功测试后的日志脚本退出码处失败，收尾修复见下文。

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

- run 40908569718 的 Android 真实收发测试已成功，但 emulator action 将多行 script 分别启动 shell，导致日志收集后的退出码变量丢失。改为独立 test-android.sh 单进程脚本；本地验证测试退出码 0/37 与日志退出码 0/13 的四种组合，均保留真实测试结果。

- Android 模拟器实际启动接收报 Permission denied。AOSP Android 15 的 SELinux app_neverallows.te 禁止普通应用创建硬链接；身份保存和最终文件提交改用 Linux/Android 的原子不覆盖移动，并补上移动完成但 SQLite 未确认时的恢复校验。参见 [AOSP 官方策略](https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/android15-release/private/app_neverallows.te)。

- Android cargo-ndk 参数改为 --platform 26，修复将 API 等级误当包名的构建失败，并统一 NDK 路径。
- Windows 使用 WinUI 3 的 Microsoft.UI.Text.FontWeights，修复字体 API 编译错误；先验证接收码再绑定批次，修复空码首次发送失败后无法重试。
- Android 按扩展名打开/分享接收文件，文件名长度对齐引擎的 180 UTF-8 字节限制；保护取消期间的原生句柄创建与清理，独立复查通过。

- 早期 Python TextIO 预读与 select 混用导致事件已在用户缓冲中却误报超时；改为线程读取队列，并保留确定性回归测试。
- axum-server 接收标准监听器前需要 set_nonblocking(true)；补上非阻塞设置及空闲停机测试，解决 macOS 接收循环阻塞。
- iOS 停机改为 stop → poll finished → release，停机期间禁止立即重启/续传，避免端口与任务重入。

## 尚未覆盖的发布条件

- 四类真实设备间 Wi-Fi、热点、访客网络、系统防火墙、相机权限拒绝/撤销，以及手机锁屏/强制退出/省电策略，仍需验收。
- CI 的网络测试为真实 HTTPS 回环，不是两台物理设备间传输；模拟器成功不能替代相机与无线网络测试。
- 未验证 GB 级文件、上万小文件、断电、磁盘满、耗电、吞吐与长期运行；不能作后台无感同步承诺。
- iOS 产物未签名，真机安装需要自己的 Apple 签名；macOS 仅 ad-hoc 签名，Windows 尚无代码签名，Android 为 debug 签名。未发布商店版本。
- 密钥保存在应用状态目录，尚未接入 Keychain/Android Keystore/Windows DPAPI；设备撤销和恢复尚未实现。
- Cargo.lock 来自通过验证的 GitHub Linux 构建（run 40905153482），已纳入源码，包含 231 个包；原子提交修复复用已锁定的 libc，并添加直接依赖记录，CI 通过 --locked 校验。最终跨平台结果仍以最新提交的构建为准。
- mDNS、目录同步、离线云端投递和其他 App 私有数据同步不在本轮范围。
