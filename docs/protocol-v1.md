# LAN transfer protocol v1 — 开发切片

此协议传送独立文件副本，不代表目录同步或备份协议。源文件只读，接收端不执行收到的内容。

## 身份与连接

邀请格式为 `msync1:` 加 URL-safe、无 padding 的 Base64 JSON：
`{version:1, host:<private IPv4>, port, certificate:<DER base64url>, token:<64 hex>}`。
邀请必须经用户自己的可信渠道交给发送方。发送端将固定 TLS 名称 `multi-sync.local` 映射到邀请中的 IPv4；仅信任邀请所带证书，禁用系统根、代理和重定向。
接收端证书和随机 capability token 在 `.multisync/identity.json` 中持久化。该 token 不是长期设备公钥配对；每份新文件仍需本地明确接受。

macOS 接收页将完整 `msync1:` 邀请作为二维码文本编码，使用 M 级纠错和四模块留白。发送端摄像头与图片识别共用解码器；仅接受有效局域网邀请，并拒绝含多个不同邀请的图片。扫码只填入连接信息，不自动发送或接受文件。移动端可沿用相同文本协议。

所有 HTTP API 要求 `Authorization: Bearer <token>`。API 没有远程 approve/reject 接口；这两个操作仅由本地客户端访问 SQLite 执行。

## 清单与端点

Manifest: `id`（UUID）、`name`（UTF-8 叶子文件名）、`size`（0..1 TiB）、`sha256`（64 个小写十六进制字符）。
Transfer: Manifest 字段加 `offset`、`state`、`final_name`。

| 请求 | 行为 |
| --- | --- |
| POST /v1/transfers | 提交 JSON Manifest；新任务 pending，同 ID 同清单幂等，不同清单拒绝 |
| GET /v1/transfers/{id} | 查询持久状态与已确认 offset |
| PUT /v1/transfers/{id}/chunks?offset=N | 二进制块，1..1 MiB；`x-chunk-sha256`；仅 receiving 状态可写 |
| POST /v1/transfers/{id}/complete | 完整性校验、提交或查询幂等完成结果 |

状态流：pending → receiving → committing → completed；pending/receiving 可转 cancelled。
整文件校验失败回到 receiving、offset=0，等待重传。认证失败 401；契约/状态/磁盘错误目前返回 409 + `{message}`。
JSON/UUID/请求体格式错误由 HTTP 框架返回 4xx。未定义接口为 404。

## 恢复与文件安全

1. 每块先验证长度/offset/hash，再写 `.multisync/{id}.part`。
2. 文件 sync 完成后以 SQLite FULL 同步事务提交 offset，之后才返回成功。
3. 恢复时只承认持久 offset。超过 offset 的未确认尾部截断；短于 offset 视为数据损坏并拒绝继续。
4. 重发已接收范围会与原字节比对，相同则幂等确认，不重复追加。
5. 校验整文件后先持久 committing 和 final_name，再用硬链接原子创建最终文件，禁止替换已有目录项。
6. 崩溃发生在最终文件出现但 completed 尚未记录时，重试验证最终文件内容后完成事务。
7. 同名文件存在时选择带任务 ID 的另一个名字。不会覆盖原件。提交与临时文件同卷。

`.multisync` 是私有状态目录，不允许自身为符号链接；远程名称拒绝分隔符、路径穿越、控制字符、Windows 保留名及结尾句点/空格。
当前威胁边界包括不可信网络与持有邀请的发送者；不防御拥有接收目录写权限的本机恶意进程竞态。每个目录仅允许一个 receiver 进程。
最多 128 个非终态任务；不预分配整个文件，不声明已做到磁盘配额预留或 DoS 防护。

## 桌面事件

Rust stdout 每行一个 JSON 对象，`event` 为 ready/jobs/job/hashing/waiting/progress/verifying/completed/error。
ready 含敏感邀请，不作为普通遥测日志收集。UI 必须收到 completed 才宣称送达。
Sender journal 先于首次网络 offer 保存，保留稳定 ID、源路径和连接信息；重新运行 `send --journal` 验证源文件后恢复。

## 后续协议演进

当前二维码承载既有接收邀请，仍不具备过期和撤销。版本协商、带时效的一次性配对、设备级授权与撤销、mDNS、目录清单、配额保留、带错误码的恢复建议、系统安全存储、移动端后台适配尚未实现。
