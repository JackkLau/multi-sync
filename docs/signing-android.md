# Android 发布签名

CI 另行生成 `MultiSync-Android-release-unsigned` 产物，包含不可直接安装的 Release APK、源码提交号和 SHA-256。CI 使用一次性测试密钥验证真实签名流程，但不上传该测试签名 APK。实际发布应在本地使用长期保留的正式密钥；常规 Debug 包继续独立提供。

[返回项目首页](../README.md) · [构建与调试](development.md)

Debug APK 已有 Android 调试签名，可用于测试。分发和后续升级应使用保管好的同一发布密钥；Release 签名不会让开发预览自动成为商店正式版本，也不会替代真机验收。Android Studio 只负责 Android 包，不能给 iOS、macOS 或 Windows 应用签名。

## 使用本地 Android Studio

1. 按[构建与调试](development.md)准备工具链和两个 ABI 的 Rust JNI 库，然后在 Android Studio 打开 **`apps/android`**。
2. 选择 **Build → Generate Signed Bundle / APK → APK**，模块选择 `app`。
3. 选择项目的发布密钥库及别名。若首次分发尚无密钥，可通过 **Create new** 创建并妥善备份；之后所有升级必须继续使用该密钥。已有分发版本时不要随意重新生成密钥。
4. 选择 **release** 构建并等待成功，记录向导显示的输出目录。向导会自行传入签名参数，无需为了使用向导把密码写入 Gradle 文件。
5. 使用以下命令验证向导产生的 APK；将路径和预期证书指纹替换为自己的实际值：

   ```sh
   sh scripts/verify-android-apk.sh /absolute/path/to/app-release.apk EXPECTED_CERTIFICATE_SHA256
   ```

检查包括签名有效性、预期签名证书、非 debuggable、ZIP 对齐以及两个 ABI 的原生引擎。此检查不修改 APK，也不等同于真机启动或文件收发测试。Android Studio / AGP 已在签名前对齐文件；签名后不要再次修改 APK。

## 可重复的本地构建

如需通过脚本复用同一发布密钥，将 [keystore.properties.example](../apps/android/keystore.properties.example) 复制为 `apps/android/keystore.properties`，只在本地填写：

| 本地属性 | 可替代的环境变量 | 含义 |
| --- | --- | --- |
| `storeFile` | `MULTISYNC_ANDROID_KEYSTORE` | 密钥库绝对路径，或相对 `apps/android` 的路径 |
| `storePassword` | `MULTISYNC_ANDROID_STORE_PASSWORD` | 密钥库密码 |
| `keyAlias` | `MULTISYNC_ANDROID_KEY_ALIAS` | 发布密钥别名 |
| `keyPassword` | `MULTISYNC_ANDROID_KEY_PASSWORD` | 私钥密码 |

环境变量优先于同名本地属性。密码按原值读取；本地文件使用 Java Properties 格式，反斜杠等字符需按该格式转义。不要把真实密码复制到 `.example`、Gradle 脚本、命令行参数、截图或提交记录中；密钥库和真实属性文件应仅在本地保留并备份。

```sh
sh scripts/build-android.sh --release
```

此 Shell 构建与校验流程用于 macOS/Linux；Windows 可通过 Android Studio 向导签名。脚本先检查签名配置，再构建 JNI 与 Release APK，并运行发布包校验。配置缺失或签名失败时直接失败，不会退回调试签名。产物为 `apps/android/app/build/outputs/apk/release/app-release.apk`。

可设置公开的证书指纹 `MULTISYNC_ANDROID_CERT_SHA256`，让验证步骤同时确认签名身份。也可再次单独调用校验脚本并把指纹作为第二个参数。指纹不包含私钥，可保存在发布说明中供下载者比对。

默认 `sh scripts/build-android.sh` 仍生成 `app-debug.apk`。显式的 `--release-unsigned` 生成 `app-release-unsigned.apk`，用于无私钥的 CI 准备流程；它不能直接安装，也不能标记为已签名发布包。

## CI 与升级

- 普通 PR 构建不需要接触发布密钥。只有受信任的发布流程才能通过环境变量读取受保护的签名凭据。
- 未签名产物应明确标记 `unsigned`；只有通过 `verify-android-apk.sh` 的 Release 包才能作为已签名 APK 分发。
- 调试签名和发布签名通常不同，同一包名的发布 APK 不能直接覆盖原有调试安装。卸载会删除应用内文件与任务，先导出需要保留的数据；不要为了安装而自动清除数据。
- 本项目最低 Android 8.0，发布配置使用 APK Signature Scheme v2。使用同一发布密钥和递增的 `versionCode` 才能持续提供正常升级。

官方参考：[Android Studio 应用签名](https://developer.android.com/studio/publish/app-signing)、[apksigner](https://developer.android.com/tools/apksigner)、[zipalign](https://developer.android.com/tools/zipalign)。
