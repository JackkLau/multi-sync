# CLI 使用

[返回项目首页](../README.md) · [构建与调试](development.md) · [协议说明](protocol-v1.md)

图形客户端可以直接显示、复制和扫描二维码。以下是面向开发者的命令行收发方式。

## 两台电脑通过 CLI 收发

两台设备均先构建 `cargo build --locked -p multi-sync`。以下以 macOS/Linux shell 为例。
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

