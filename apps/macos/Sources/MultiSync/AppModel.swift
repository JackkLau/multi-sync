import AppKit
import Combine
import Darwin
import MultiSyncKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var section = "send"
    @Published var invitation = ""
    @Published var revealInvitation = false
    @Published var showingScanner = false
    @Published var readingQRCode = false
    @Published var files: [URL] = []
    @Published var outgoing: [SendRecord] = []
    @Published var incoming: [ReceivedTransfer] = []
    @Published var receiverRunning = false
    @Published var receivingTicket = ""
    @Published var receivingQRCode: CGImage?
    @Published var receivingAddress = ""
    @Published var localAddress = AppModel.suggestedAddress()
    @Published var inbox: URL
    @Published var engine: URL?
    @Published var notice: String?
    @Published var activeSend: UUID?
    @Published var speed: Double = 0
    private let dataRoot: URL
    private var receiver: EngineProcess?
    private var sender: EngineProcess?
    private var commands: [UUID: EngineProcess] = [:]
    private var poller: Task<Void, Never>?
    private var refreshing = false
    private var canSave = true
    private var lastSave = Date.distantPast
    private var invitations: [UUID: String] = [:]
    private var queueURL: URL { dataRoot.appendingPathComponent("queue.json") }

    init() {
        let override = ProcessInfo.processInfo.environment["MULTISYNC_HOME"]
        dataRoot = override.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MultiSync")
        inbox = override == nil
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("MultiSync")
            : dataRoot.appendingPathComponent("Inbox")
        engine = Self.locateEngine()
        do { outgoing = try QueuePersistence.load(from: queueURL) }
        catch { canSave = false; notice = "任务记录无法读取，已保留原记录。请检查 \(queueURL.path)：\(error.localizedDescription)" }
        if let saved = UserDefaults.standard.string(forKey: "receiveDirectory"), override == nil { inbox = URL(fileURLWithPath: saved) }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshIncoming()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    static func locateEngine() -> URL? {
        let paths: [String?] = [ProcessInfo.processInfo.environment["MULTISYNC_ENGINE"],
                     Bundle.main.url(forAuxiliaryExecutable: "multi-sync")?.path,
                     URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/debug/multi-sync").path]
        return paths.compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    static func suggestedAddress() -> String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return "127.0.0.1" }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if !value.hasPrefix("127.") && Invitation.isLocalIPv4(value) { return value }
            }
        }
        return "127.0.0.1"
    }

    func selectEngine() {
        let panel = NSOpenPanel(); panel.title = "选择已构建的 multi-sync 引擎"
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.isExecutableFile(atPath: url.path) else { notice = "所选文件不可执行。请先运行构建脚本。"; return }
            engine = url; notice = nil
        }
    }
    func selectFiles() {
        let panel = NSOpenPanel(); panel.title = "选择要发送的文件"
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { files = Array(Set(files + panel.urls)).sorted { $0.path < $1.path } }
    }
    func selectInbox() {
        guard !receiverRunning else { return }
        let panel = NSOpenPanel(); panel.title = "选择接收目录"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            inbox = url; incoming = []; UserDefaults.standard.set(url.path, forKey: "receiveDirectory")
        }
    }
    func showInbox() { NSWorkspace.shared.open(inbox) }
    func showReceived(_ job: ReceivedTransfer) {
        guard let name = job.final_name, job.state == "completed" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([inbox.appendingPathComponent(name)])
    }
    func copyTicket() {
        guard !receivingTicket.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(receivingTicket, forType: .string)
        notice = "接收邀请已复制。仅分享给你要接收文件的设备；每份文件仍需你确认。"
    }

    func acceptScannedInvitation(_ value: String) {
        guard Invitation.isPlausible(value) else {
            notice = "二维码不是有效的 MultiSync 接收邀请，请重新扫描。"
            return
        }
        invitation = value.trimmingCharacters(in: .whitespacesAndNewlines)
        revealInvitation = false; section = "send"
        notice = "已识别接收邀请。选择要发送的文件后，点击发送；对方仍需确认接收。"
    }

    func selectQRCodeImage() {
        guard !readingQRCode else { return }
        let panel = NSOpenPanel(); panel.title = "选择接收二维码图片"
        panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readingQRCode = true
        Task {
            defer { readingQRCode = false }
            do {
                let invitation = try await Task.detached(priority: .userInitiated) {
                    try InvitationQRCode.recognize(imageAt: url)
                }.value
                acceptScannedInvitation(invitation)
            } catch { notice = error.localizedDescription }
        }
    }

    func startReceiving() {
        guard receiver == nil, let engine else { return }
        guard Invitation.isLocalIPv4(localAddress) else { notice = "请输入本机的局域网 IPv4 地址，例如 192.168.1.8。"; return }
        let runner = EngineProcess(); receiver = runner; receiverRunning = true; notice = nil
        do {
            try runner.start(executable: engine, arguments: ["receive", "--inbox", inbox.path, "--advertise", localAddress], onEvent: { [weak self] event in
                guard let self else { return }
                if event.event == "ready" {
                    receivingTicket = event.ticket ?? ""; receivingAddress = event.address ?? ""
                    do { receivingQRCode = try InvitationQRCode.makeImage(receivingTicket) }
                    catch { notice = error.localizedDescription }
                    refreshIncoming()
                }
                if event.event == "error" { notice = event.message }
            }, onExit: { [weak self] code in
                guard let self else { return }
                receiver = nil; receiverRunning = false; receivingTicket = ""; receivingQRCode = nil; receivingAddress = ""
                if code != 0 && notice == nil { notice = "接收服务已停止（\(code)）。检查端口占用、目录权限后重新开启。" }
            })
        } catch { receiver = nil; receiverRunning = false; notice = error.localizedDescription }
    }
    func stopReceiving() { receiver?.stop() }

    func sendSelected() {
        guard canSave, engine != nil, !files.isEmpty else { return }
        guard Invitation.isPlausible(invitation) else { notice = "接收邀请无效。请在对方设备开启接收后复制完整邀请。"; return }
        do {
            var additions: [SendRecord] = []
            for file in files {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard info.isRegularFile == true else { notice = "首版只支持普通文件，请展开文件夹后选择文件。"; return }
                additions.append(SendRecord(source: file, size: UInt64(info.fileSize ?? 0)))
            }
            try QueuePersistence.save(outgoing + additions, to: queueURL)
            outgoing += additions
            for record in additions { invitations[record.id] = invitation.trimmingCharacters(in: .whitespacesAndNewlines) }
            files = []; notice = nil
            startNext()
        } catch { notice = "无法保存发送任务：\(error.localizedDescription)" }
    }
    private func startNext() {
        guard activeSend == nil, let next = outgoing.first(where: { $0.phase == .queued && invitations[$0.id] != nil }) else { return }
        resume(next.id)
    }
    func resume(_ id: UUID) {
        guard activeSend == nil, canSave, let engine, let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        let record = outgoing[index]
        let journal = dataRoot.appendingPathComponent("outgoing/\(id.uuidString).json")
        let exists = FileManager.default.fileExists(atPath: journal.path)
        let ticket = invitations[id] ?? invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard exists || Invitation.isPlausible(ticket) else { notice = "此任务尚未建立连接。请先粘贴接收邀请，再点击继续。"; return }
        var args = ["send", "--journal", journal.path]
        if !exists { args += ["--source", record.source] }
        outgoing[index].phase = .hashing; outgoing[index].message = nil
        guard persist() else { outgoing[index].phase = .failed; return }
        let runner = EngineProcess(); sender = runner; activeSend = id; speed = 0; notice = nil
        do {
            try runner.start(executable: engine, arguments: args, input: exists ? nil : ticket, onEvent: { [weak self] event in
                guard let self, activeSend == id, let i = outgoing.firstIndex(where: { $0.id == id }), outgoing[i].phase != .paused else { return }
                outgoing[i].apply(event)
                if let speed = event.bytes_per_second { self.speed = speed }
                if event.event != "progress" || Date().timeIntervalSince(lastSave) > 1 { _ = persist() }
            }, onExit: { [weak self] code in
                guard let self, activeSend == id else { return }
                if let i = outgoing.firstIndex(where: { $0.id == id }), ![.paused, .failed, .completed].contains(outgoing[i].phase) {
                    outgoing[i].phase = .failed
                    outgoing[i].message = "传输进程已结束（\(code)）。检查两台设备在线后重试。"
                }
                activeSend = nil; sender = nil; _ = persist()
                if outgoing.first(where: { $0.id == id })?.phase == .completed { invitations.removeValue(forKey: id); startNext() }
            })
        } catch {
            outgoing[index].phase = .failed; outgoing[index].message = error.localizedDescription
            activeSend = nil; sender = nil; _ = persist()
        }
    }
    func pause(_ id: UUID) {
        guard activeSend == id, let i = outgoing.firstIndex(where: { $0.id == id }) else { return }
        outgoing[i].phase = .paused; _ = persist(); sender?.stop()
    }
    @discardableResult private func persist() -> Bool {
        guard canSave else { return false }
        do { try QueuePersistence.save(outgoing, to: queueURL); lastSave = Date(); return true }
        catch { notice = "任务记录保存失败：\(error.localizedDescription)"; return false }
    }
    private func command(_ args: [String], event: @escaping (EngineEvent) -> Void, completion: @escaping () -> Void = {}) {
        guard let engine else { completion(); return }
        let id = UUID(); let runner = EngineProcess(); commands[id] = runner
        do {
            try runner.start(executable: engine, arguments: args, onEvent: { [weak self] value in
                if value.event == "error" { self?.notice = value.message }
                event(value)
            }, onExit: { [weak self] _ in self?.commands.removeValue(forKey: id); completion() })
        } catch { commands.removeValue(forKey: id); notice = error.localizedDescription; completion() }
    }
    func refreshIncoming() {
        guard !refreshing, engine != nil, FileManager.default.fileExists(atPath: inbox.appendingPathComponent(".multisync/tasks.sqlite3").path) else { return }
        refreshing = true
        let requestedInbox = inbox
        command(["jobs", "--inbox", inbox.path], event: { [weak self] value in
            if self?.inbox == requestedInbox, let jobs = value.jobs { self?.incoming = jobs }
        }, completion: { [weak self] in self?.refreshing = false })
    }
    func decide(_ job: ReceivedTransfer, accept: Bool) {
        let requestedInbox = inbox
        command([accept ? "approve" : "reject", "--inbox", inbox.path, "--id", job.id], event: { [weak self] value in
            if self?.inbox == requestedInbox, let changed = value.job, let i = self?.incoming.firstIndex(where: { $0.id == changed.id }) { self?.incoming[i] = changed }
        })
    }
    func shutdown() {
        poller?.cancel()
        if let id = activeSend { pause(id) }
        receiver?.stop(); commands.values.forEach { $0.stop() }
    }
}
