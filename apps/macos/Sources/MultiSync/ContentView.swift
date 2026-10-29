import SwiftUI
import MultiSyncKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.swap").font(.title2.bold()).foregroundStyle(Theme.accent)
                    Text("MultiSync").font(.system(size: 21, weight: .bold, design: .rounded))
                }.padding(.top, 22)
                VStack(spacing: 8) {
                    navigation("发送文件", symbol: "arrow.up.doc", key: "send")
                    navigation("接收文件", symbol: "tray.and.arrow.down", key: "receive")
                }
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    Label(model.receiverRunning ? "接收已开启" : "接收未开启", systemImage: model.receiverRunning ? "dot.radiowaves.left.and.right" : "pause.circle")
                    Text("同一网络 · 保留原件").font(.caption)
                    Text("0.1 开发预览").font(.caption2).foregroundStyle(Theme.muted)
                }.foregroundStyle(Theme.muted)
            }.padding(22).frame(width: 210).frame(maxHeight: .infinity).background(.white)
            Rectangle().fill(Theme.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if model.engine == nil {
                        Surface {
                            Label("传输引擎尚未构建", systemImage: "wrench.and.screwdriver").font(.headline)
                            Text("界面可以运行。完成项目的 Rust 构建后，选择 multi-sync 可执行文件即可收发。").foregroundStyle(Theme.muted)
                            Button("选择传输引擎…", action: model.selectEngine)
                        }
                    }
                    if let notice = model.notice {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "info.circle")
                            Text(notice).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Button { model.notice = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
                        }.padding(16).background(Theme.line.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityElement(children: .combine)
                    }
                    if model.section == "send" { sendContent } else { receiveContent }
                }.padding(30).frame(maxWidth: 920, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Theme.canvas)
        }.foregroundStyle(Theme.ink)
            .sheet(isPresented: $model.showingScanner) {
                QRScannerView(onCode: model.acceptScannedInvitation)
            }
    }
    private func navigation(_ title: String, symbol: String, key: String) -> some View {
        Button { model.section = key } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if key == "receive", model.incoming.contains(where: { $0.state == "pending" }) {
                    Text("\(model.incoming.filter { $0.state == "pending" }.count)").font(.caption.bold())
                }
            }.padding(12).frame(maxWidth: .infinity)
                .background(model.section == key ? Theme.line.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityAddTraits(model.section == key ? .isSelected : [])
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.section == "send" ? "把文件送到另一台设备" : "为收到的文件留个位置")
                .font(.system(size: 27, weight: .semibold, design: .rounded))
            Text(model.section == "send" ? "选择原文件，扫描对方的接收二维码。发送后原件仍在这里。" : "开启接收，让发送方扫描二维码。每份文件都由你确认。")
                .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8)
    }
    private var sendContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Surface {
                HStack {
                    Label("待发送文件", systemImage: "doc.on.doc").font(.headline)
                    Spacer()
                    Button("选择文件…", action: model.selectFiles)
                }
                if model.files.isEmpty {
                    HStack(spacing: 18) {
                        Image(systemName: "doc.badge.plus").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("照片、视频、文档，保留原始内容").font(.headline)
                            Text("可一次选择多个文件，按顺序发送。首版暂不支持文件夹。").foregroundStyle(Theme.muted).font(.callout)
                        }
                    }.padding(.vertical, 14)
                } else {
                    ForEach(model.files, id: \.path) { file in
                        HStack {
                            Image(systemName: "doc")
                            Text(file.lastPathComponent).lineLimit(2).help(file.path)
                            Spacer()
                            Button { model.files.removeAll { $0 == file } } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).help("移除 \(file.lastPathComponent)").accessibilityLabel("移除 \(file.lastPathComponent)")
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("连接接收设备").font(.headline)
                    HStack(spacing: 12) {
                        Button { model.showingScanner = true } label: { Label("扫码识别", systemImage: "qrcode.viewfinder") }
                            .disabled(model.readingQRCode)
                        Button("从二维码图片识别…", action: model.selectQRCodeImage).disabled(model.readingQRCode)
                        Button("从剪贴板导入", action: model.pasteTicket).disabled(model.readingQRCode)
                        if model.readingQRCode { ProgressView().controlSize(.small).accessibilityLabel("正在识别二维码") }
                    }
                    HStack {
                        Group {
                            if model.revealInvitation { TextField("msync1:…", text: $model.invitation) }
                            else { SecureField("扫码后自动连接，无需手动填写", text: $model.invitation) }
                        }.textFieldStyle(.roundedBorder).accessibilityLabel("对方的接收邀请")
                        Button { model.revealInvitation.toggle() } label: { Image(systemName: model.revealInvitation ? "eye.slash" : "eye") }
                            .help(model.revealInvitation ? "隐藏邀请" : "显示邀请").accessibilityLabel(model.revealInvitation ? "隐藏邀请" : "显示邀请")
                    }
                    Text("两台设备需连接同一 Wi-Fi、手机热点或路由器。访客网络可能阻止连接。")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                HStack {
                    Label("原文件始终保留", systemImage: "checkmark.shield").font(.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("发送\(model.files.isEmpty ? "文件" : " \(model.files.count) 个文件")", action: model.sendSelected)
                        .buttonStyle(.borderedProminent).disabled(model.files.isEmpty || model.engine == nil || model.invitation.isEmpty)
                }
            }
            HStack { Text("发送任务").font(.title3.bold()); Spacer(); Text("\(model.outgoing.count) 项").foregroundStyle(Theme.muted) }
            if model.outgoing.isEmpty {
                Text("还没有发送任务。完成后可在这里确认送达结果。").foregroundStyle(Theme.muted).padding(.vertical, 12)
            }
            ForEach(model.outgoing.reversed()) { record in sendRow(record) }
        }
    }
    private func sendRow(_ record: SendRecord) -> some View {
        Surface {
            HStack(alignment: .top) {
                Image(systemName: record.phase == .completed ? "checkmark.circle.fill" : "doc").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.name).font(.headline).lineLimit(2).help(record.source)
                    Text(record.phase.label).font(.callout).foregroundStyle(Theme.muted)
                }
                Spacer()
                if model.activeSend == record.id {
                    Button("暂停") { model.pause(record.id) }.disabled(record.phase == .paused)
                } else if record.phase != .completed {
                    Button(record.phase == .failed ? "重试" : "继续") { model.resume(record.id) }.disabled(model.activeSend != nil || model.engine == nil)
                }
            }
            ProgressView(value: record.progress).accessibilityLabel("\(record.name) 发送进度")
            HStack {
                Text("\(byteCount(record.offset)) / \(byteCount(record.size))").monospacedDigit()
                Spacer()
                if model.activeSend == record.id && record.phase == .progress { Text("\(byteCount(UInt64(max(0, model.speed))))/s").monospacedDigit() }
            }.font(.caption).foregroundStyle(Theme.muted)
            if let message = record.message { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let final = record.finalName, final != record.name { Text("对方保存为：\(final)").font(.caption).textSelection(.enabled) }
        }
    }
    private var receiveContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Surface {
                HStack {
                    Label("接收目录", systemImage: "folder").font(.headline)
                    Spacer()
                    Button("更改…", action: model.selectInbox).disabled(model.receiverRunning)
                }
                Text(model.inbox.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled).foregroundStyle(Theme.muted)
                HStack {
                    Text("本机局域网地址")
                    TextField("例如 192.168.1.8", text: $model.localAddress).textFieldStyle(.roundedBorder)
                        .disabled(model.receiverRunning).accessibilityLabel("本机局域网 IPv4 地址")
                }
                if model.localAddress.hasPrefix("127.") { Text("当前是本机测试地址。跨设备传输时，请填写电脑的 Wi-Fi 或有线网络地址。") .font(.caption).foregroundStyle(Theme.muted) }
                HStack {
                    Label(model.receiverRunning ? (model.receivingTicket.isEmpty ? "正在启动接收…" : "接收已开启 · \(model.receivingAddress)") : "开启接收后自动生成本机二维码，无需输入接收码", systemImage: "network")
                        .font(.callout).foregroundStyle(Theme.muted)
                    Spacer()
                    if model.receiverRunning { Button("停止接收", action: model.stopReceiving) }
                    else { Button("开启接收", action: model.startReceiving).buttonStyle(.borderedProminent).disabled(model.engine == nil) }
                }
                if !model.receivingTicket.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 16) {
                        Text("让发送设备扫描此二维码").font(.headline)
                        if let code = model.receivingQRCode {
                            Image(decorative: code, scale: 2)
                                .interpolation(.none).resizable().scaledToFit()
                                .frame(width: 300, height: 300)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("MultiSync 接收二维码，包含本机连接凭据")
                            ShareLink(item: Image(decorative: code, scale: 1),
                                      preview: SharePreview("MultiSync 接收二维码", image: Image(decorative: code, scale: 1))) {
                                Label("分享二维码", systemImage: "square.and.arrow.up")
                            }
                        }
                        Text("在发送设备的 MultiSync 中点击“扫码识别”。二维码包含接收密钥，请只展示给要连接的设备。")
                            .font(.callout).foregroundStyle(Theme.muted)
                        HStack {
                            Button("复制接收码", action: model.copyTicket)
                            Button("复制二维码", action: model.copyQRCode)
                            Button("保存二维码…", action: model.saveQRCode)
                        }
                        Label("扫码后仍需你确认每份文件", systemImage: "checkmark.shield").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
            HStack {
                Text("接收任务").font(.title3.bold()); Spacer()
                Button("打开接收目录", action: model.showInbox)
            }
            if model.incoming.isEmpty { Text("暂时没有文件。请在另一台设备选择文件并扫描接收二维码。").foregroundStyle(Theme.muted).padding(.vertical, 12) }
            ForEach(model.incoming) { job in
                Surface {
                    HStack(alignment: .top) {
                        Image(systemName: job.state == "completed" ? "checkmark.circle.fill" : "arrow.down.doc").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.name).font(.headline).lineLimit(2)
                            Text("\(byteCount(job.size)) · \(job.stateLabel)").font(.callout).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if job.state == "pending" {
                            Button("拒绝") { model.decide(job, accept: false) }
                            Button("接受") { model.decide(job, accept: true) }.buttonStyle(.borderedProminent)
                        } else if job.state == "completed" { Button("在 Finder 中显示") { model.showReceived(job) } }
                    }
                    if job.state == "receiving" || job.state == "committing" { ProgressView(value: job.progress).accessibilityLabel("\(job.name) 接收进度") }
                    if let final = job.final_name, final != job.name { Text("保存为：\(final)").font(.caption).textSelection(.enabled) }
                }
            }
        }
    }
}
