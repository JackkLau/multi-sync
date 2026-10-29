import SwiftUI
import UIKit

// Native adapters mirror the canonical palette in DESIGN.md.
enum MobileTheme {
    static let accent = Color(red: 9 / 255, green: 108 / 255, blue: 116 / 255)
    static let canvas = Color(red: 244 / 255, green: 248 / 255, blue: 249 / 255)
    static let ink = Color(red: 24 / 255, green: 50 / 255, blue: 56 / 255)
}
private struct Surface<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }
}
private enum PickerKind: String, Identifiable { case files, qr; var id: String { rawValue } }

struct ContentView: View {
    @EnvironmentObject private var model: MobileModel
    @State private var selectedTab = 1
    @State private var picker: PickerKind?
    @State private var showScanner = false
    @State private var share: ShareItems?
    @State private var preview: PreviewFile?
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                page { sendPage }.navigationTitle("发送文件")
            }.tabItem { Label("发送", systemImage: "arrow.up.doc") }.tag(0)
            NavigationStack {
                page { receivePage }.navigationTitle("接收文件")
            }.tabItem { Label("接收", systemImage: "tray.and.arrow.down") }.tag(1)
        }
        .sheet(item: $picker) { kind in
            DocumentPicker(imagesOnly: kind == .qr) { urls in
                picker = nil
                if kind == .qr, let url = urls.first { model.recognizeFile(url) }
                if kind == .files { model.importFiles(urls) }
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { value in model.acceptDestination(value); selectedTab = 0 }
        }
        .sheet(item: $share) { ActivitySheet(items: $0.items) }
        .sheet(item: $preview) { FilePreview(url: $0.url) }
    }
    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let notice = model.notice {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle")
                        Text(notice).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { model.notice = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("关闭提示").buttonStyle(.plain)
                    }.padding(16).background(MobileTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                }
                content()
            }.padding(16).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }.background(MobileTheme.canvas).foregroundStyle(MobileTheme.ink)
    }
    private var sendPage: some View {
        Group {
            Surface {
                Label("先连接，再发送", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                Text("扫描对方的接收二维码，即可识别设备。发送后两端都保留独立副本。")
                    .foregroundStyle(.secondary)
                Button { showScanner = true } label: { Label("扫码连接", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity, minHeight: 28) }
                    .buttonStyle(.borderedProminent).disabled(model.recognizing)
                HStack {
                    Button("识别二维码图片") { picker = .qr }.disabled(model.recognizing)
                    Spacer()
                    Button("从剪贴板粘贴", action: model.pasteDestination).disabled(model.recognizing)
                }.font(.subheadline)
                if model.recognizing { ProgressView("正在识别二维码") }
                if !model.destination.isEmpty {
                    HStack {
                        Label(model.destinationLabel, systemImage: "checkmark.shield").font(.subheadline)
                        Spacer()
                        Button("清除", action: model.clearDestination)
                    }
                }
            }
            Surface {
                HStack {
                    Text("待发送文件").font(.headline)
                    Spacer()
                    Button { picker = .files } label: { Label("添加", systemImage: "plus") }.disabled(model.importing)
                }
                if model.importing { ProgressView("正在准备文件，原件会保留") }
                if model.staged.isEmpty { Text("选择照片、视频或文档。可从“文件”中的本机、iCloud Drive 或其他已授权位置添加。").foregroundStyle(.secondary) }
                ForEach(model.staged) { file in
                    HStack(alignment: .top) {
                        Image(systemName: "doc")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).lineLimit(3)
                            Text(size(file.size)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.staged.removeAll { $0.id == file.id } } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("移除 \(file.name)")
                    }
                }
                Button(action: model.sendSelected) {
                    Label(model.startingSend ? "正在开始" : "发送文件", systemImage: "arrow.up.doc")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }.buttonStyle(.borderedProminent)
                    .disabled(model.destination.isEmpty || model.staged.isEmpty || model.activeID != nil || model.importing || !model.canSaveHistory || model.startingSend || model.senderStopping)
                Text("两台设备需在同一网络，收发时保持应用在前台。").font(.footnote).foregroundStyle(.secondary)
            }
            Text("发送回执").font(.title3.bold()).padding(.top, 4)
            if model.outgoing.isEmpty {
                Surface { Label("还没有发送任务", systemImage: "tray"); Text("完成后会显示校验结果；中断的任务可以继续。").foregroundStyle(.secondary) }
            }
            ForEach(model.outgoing) { record in
                Surface {
                    Text(record.name).font(.headline).textSelection(.enabled)
                    Label(record.phase.label, systemImage: record.phase == .completed ? "checkmark.circle" : "arrow.up.doc")
                    ProgressView(value: record.progress).accessibilityLabel("发送进度")
                    Text("\(size(record.offset)) / \(size(record.size))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let message = record.message { Text(message).font(.subheadline).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    if model.activeID == record.id {
                        if model.senderStopping { ProgressView("正在保存进度并暂停") }
                        else { Button("暂停发送", action: model.pauseAll) }
                    } else if record.phase != .completed {
                        Button(record.phase == .failed ? "重试" : "继续发送") { model.resume(record.id) }
                            .disabled(model.activeID != nil || model.startingSend || model.senderStopping || !model.canSaveHistory)
                    }
                }
            }
        }
    }
    private var receivePage: some View {
        Group {
            Surface {
                Label(model.receiving ? "接收已开启" : "让另一台设备发给你", systemImage: model.receiving ? "antenna.radiowaves.left.and.right" : "tray.and.arrow.down")
                    .font(.title3.bold())
                Text("开启接收后，本机会直接生成二维码和接收码，无需粘贴任何内容。").foregroundStyle(.secondary)
                if model.receiving, let image = model.receivingQR {
                    Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                        .frame(maxWidth: 340).frame(maxWidth: .infinity)
                        .accessibilityLabel("本机接收二维码，包含连接凭据")
                    HStack {
                        Button(action: model.copyReceivingCode) { Label("复制接收码", systemImage: "doc.on.doc") }
                        Spacer()
                        Button { share = ShareItems(items: [UIImage(cgImage: image)]) } label: { Label("分享二维码", systemImage: "square.and.arrow.up") }
                    }.buttonStyle(.bordered)
                    Text("仅分享给你信任的设备。每份文件仍会询问你是否接收。").font(.footnote).foregroundStyle(.secondary)
                }
                if !model.receiving && !model.receiverStarting && !model.receiverStopping {
                    if model.addresses.isEmpty {
                        Text("未检测到局域网地址。请先连接 Wi-Fi 或另一台设备的热点。").foregroundStyle(.secondary)
                    } else {
                        Picker("本机局域网地址", selection: $model.selectedAddress) {
                            ForEach(model.addresses, id: \.self) { address in Text(address).tag(address) }
                        }.pickerStyle(.menu)
                    }
                    Button("刷新网络地址", action: model.refreshAddresses)
                }
                if model.receiverStopping {
                    ProgressView("正在安全停止接收")
                } else if model.receiving || model.receiverStarting {
                    if model.receiverStarting { ProgressView("正在开启接收") }
                    Button("停止接收", action: model.stopReceiving).buttonStyle(.bordered)
                } else {
                    Button(action: model.startReceiving) { Label("开启接收", systemImage: "qrcode").frame(maxWidth: .infinity, minHeight: 28) }
                        .buttonStyle(.borderedProminent).disabled(model.selectedAddress.isEmpty)
                }
                Text("接收文件保存到“文件 → 我的 iPhone/iPad → MultiSync → Inbox”。切到后台会暂停收发，任务仍会保留。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("收件箱").font(.title3.bold()).padding(.top, 4)
            if model.incoming.isEmpty {
                Surface { Label("等待你的文件", systemImage: "tray"); Text("开启接收并分享二维码后，对方发送的文件会出现在这里。").foregroundStyle(.secondary) }
            }
            ForEach(model.incoming) { job in
                Surface {
                    Text(job.name).font(.headline).textSelection(.enabled)
                    Text(job.stateLabel)
                    ProgressView(value: job.progress).accessibilityLabel("接收进度")
                    Text("\(size(job.offset)) / \(size(job.size))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if job.state == "pending" {
                        HStack {
                            Button("接收文件") { model.decide(job, accept: true) }.buttonStyle(.borderedProminent)
                            Button("拒绝") { model.decide(job, accept: false) }.buttonStyle(.bordered)
                        }.disabled(model.decidingIDs.contains(job.id))
                    }
                    if job.state == "completed" {
                        HStack {
                            Button("打开预览") { if let url = model.receivedURL(job) { preview = PreviewFile(url: url) } }
                            Spacer()
                            Button { if let url = model.receivedURL(job) { share = ShareItems(items: [url]) } } label: { Label("分享或另存", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
            }
        }
    }
    private func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
}
