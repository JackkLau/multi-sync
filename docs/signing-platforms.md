# Apple 与 Windows 签名

[返回首页](../README.md) · [构建与调试](development.md)

Android Studio 负责 Android APK 的签名。iOS/macOS 使用 Apple 签名身份，Windows 使用代码签名证书；Android keystore 不能用于这些平台。

下列脚本提供可选签名模式。默认命令仍输出开发预览包；显式要求签名时，缺少证书、私钥、描述文件或签名验证失败都会中止，不会退回未签名产物冒充成功。签名模式只读取已配置的身份，不创建证书、不改变系统信任，也不向商店上传应用。

| 平台 | 签名所需条件 | 签名模式输出 |
| --- | --- | --- |
| macOS | 钥匙串中已有 Apple 签名证书和对应私钥；对外分发使用 Developer ID Application | `dist/MultiSync-macOS-signed.zip`；签名不等于公证 |
| iPhone / iPad | Apple Team、签名身份、已安装且匹配 bundle ID 的 provisioning profile、Xcode 导出配置 | `dist/ios/MultiSync-iOS-signed.ipa`；可安装设备由描述文件决定 |
| Windows x64 | CurrentUser 的 `My` 证书库中已有代码签名证书与私钥、Windows SDK SignTool | `dist/MultiSync-Windows-x64-signed.zip`；包含已验证的时间戳签名 |

签名证书需要持有人提供；构建脚本无法替代证书申请或设备注册。没有配置这些条件时，CI 默认产物仍是未签名 iOS/Windows 预览和 ad-hoc 签名 macOS 预览。

## macOS

先用 `security find-identity -v -p codesigning` 查看本机可用身份。选用自己的身份名称或 SHA-1 指纹：

```sh
export MULTISYNC_MACOS_SIGNING_IDENTITY='Developer ID Application: Your Name (YOURTEAMID)'
sh scripts/build-macos.sh --signed
```

脚本先签名内置 Rust 可执行文件，再签名应用包，启用 Hardened Runtime 和安全时间戳，最后递归检查签名与 Apple 证书来源。外层应用只增加二维码扫码所需的 `com.apple.security.device.camera` entitlement，并检查其已写入签名；CLI 不申请相机权限。安全时间戳需要网络。`--signed` 不接受 `--ui-only`，避免把缺少传输引擎的界面包当作完整签名版本。

此命令不提交 Apple 公证；分发前仍需使用自己的 Apple 账户完成公证与验收。不要通过禁用 Gatekeeper 或修改证书信任来掩盖签名问题。

## iPhone / iPad

在 Xcode 中为目标 bundle ID 配置自己的 Team、证书和描述文件。导出一次适合目标设备与分发方式的 `ExportOptions.plist`，或按当前 Xcode 文档填写。脚本要求：

- `signingStyle` 为 `manual`，`teamID` 与环境变量一致。
- 明确填写 `method`、`signingCertificate` 及 `provisioningProfiles` 中当前 bundle ID 对应的 profile。
- `destination` 为 `export` 或省略；不接受 `upload`。

```sh
export MULTISYNC_IOS_TEAM_ID='YOURTEAMID'
export MULTISYNC_IOS_SIGNING_IDENTITY='Apple Development: Your Name (CERTIFICATEID)'
export MULTISYNC_IOS_PROVISIONING_PROFILE='Your installed profile name or UUID'
export MULTISYNC_IOS_EXPORT_OPTIONS_PLIST='/absolute/path/ExportOptions.plist'
# 仅当自己的描述文件使用其他标识符时设置；默认 local.multisync.mobile。
export MULTISYNC_IOS_BUNDLE_ID='com.example.multisync'
sh scripts/build-ios.sh --test --signed
```

脚本保留现有设备/模拟器构建与可选测试，再用指定签名参数执行 `archive` 和 `-exportArchive`。导出 IPA 会重新解包验证签名和内嵌描述文件，验证成功后才复制为 `MultiSync-iOS-signed.ipa`。不会自动更新开发者门户或开启 `-allowProvisioningUpdates`。

Apple Development、开发测试、Ad Hoc、App Store 分发的证书与描述文件需要相互匹配；签名成功不表示可安装到任意 iPhone。原先的 `MultiSync-iOS-unsigned.ipa` 名称继续明确表示未签名包。

## Windows

在自己的签名工作站上准备受信任的代码签名证书和私钥。若证书以 PFX 提供，请先使用 Windows 证书管理界面导入 CurrentUser → Personal（`My`），或使用证书供应商支持的硬件密钥流程。脚本不接收命令行 PFX 密码。

```powershell
$env:MULTISYNC_WINDOWS_CERTIFICATE_THUMBPRINT = 'YOUR_40_HEX_CERTIFICATE_THUMBPRINT'
$env:MULTISYNC_SIGNTOOL_PATH = 'C:\Program Files (x86)\Windows Kits\10\bin\YOUR_SDK_VERSION\x64\signtool.exe'
pwsh -File scripts/build-windows.ps1 -Sign
```

若 `signtool.exe` 已在 `PATH` 中，可省略路径变量。时间戳服务器默认使用 `http://timestamp.digicert.com`，也可通过 `MULTISYNC_WINDOWS_TIMESTAMP_URL` 指定自己的受支持 HTTP(S) RFC 3161 服务；地址不得内嵌凭据。

脚本只签名项目自己的 `MultiSync.Windows.exe`、`MultiSync.Windows.dll` 和 `multi_sync_bridge.dll`，保留第三方运行库的原签名。使用 SHA-256 文件摘要及时间戳，逐个执行 SignTool 的 Authenticode 验证，并检查签名证书指纹和时间戳。证书不受信任、验证失败或时间戳缺失时不生成新的已签名 ZIP。

## 凭据与验证边界

私钥、PFX/P12、描述文件和导出配置应保存在本机受保护位置；如在 CI 使用，则通过对应平台的受保护凭据机制注入，不提交到 Git，也不输出密码。证书名称与指纹用于选择身份，不是私钥的替代品。

当前仓库已加入签名参数与失败保护；若执行环境没有真实证书，不能据此宣称完成可信签名、公证或商店分发。成功产物必须结合签名工具结果、实际证书与真机安装验证。

## 官方参考

- [Apple：创建 macOS 分发签名](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Apple：命令行 archive 与 export](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)
- [Apple：导出配置文件](https://help.apple.com/xcode/mac/current/en.lproj/deva1f2ab5a2.html)
- [Microsoft：SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool)
