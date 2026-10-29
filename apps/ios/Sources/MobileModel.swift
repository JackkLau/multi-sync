import Foundation
import SwiftUI
import UIKit

@MainActor
final class MobileModel: ObservableObject {
    @Published var addresses: [String] = []
    @Published var selectedAddress = ""
    @Published var receiverStarting = false
    @Published var receiverStopping = false
    @Published var receiving = false
    @Published var receivingTicket = ""
    @Published var receivingQR: CGImage?
    @Published var destination = ""
    @Published var destinationLabel = "尚未连接发送目标"
    @Published var notice: String?
    @Published var staged: [StagedFile] = []
    @Published var importing = false
    @Published var recognizing = false
    @Published var outgoing: [SendRecord] = []
    @Published var incoming: [ReceivedTransfer] = []
    @Published var activeID: UUID?
    @Published var startingSend = false
    @Published var senderStopping = false
    @Published var decidingIDs: Set<String> = []
    @Published var canSaveHistory = true
    private var receiverHandle: String?
    private var senderHandle: String?
    private var receiverGeneration = UUID()
    private var sendGeneration = UUID()
    private var destinationGeneration = UUID()
    private var pendingIDs: [UUID] = []
    private var batchTicket = ""
    private var foreground = true
    private var pollTask: Task<Void, Never>?
    private var tickCount = 0

    init() {
        do {
            try MobileFiles.prepare()
            outgoing = try QueuePersistence.load(from: MobileFiles.history)
        } catch {
            canSaveHistory = false
            notice = "无法读取任务历史，已停止新任务以保护旧记录：\(error.localizedDescription)"
        }
        refreshAddresses()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    func refreshAddresses() {
        addresses = MobileFiles.localAddresses()
        if !addresses.contains(selectedAddress) { selectedAddress = addresses.first ?? "" }
    }
    func activate() { foreground = true; refreshAddresses() }
    func background() {
        foreground = false
        let wasActive = receiving || receiverStarting || senderHandle != nil || startingSend
        stopReceiving(); pauseAll()
        if wasActive { notice = "应用已进入后台，收发已暂停并保留任务。回到应用后可重新开启接收或继续发送。" }
    }

    func startReceiving() {
        guard foreground, !receiverStarting, !receiverStopping, !receiving, !selectedAddress.isEmpty else { return }
        receiverStarting = true
        receiverGeneration = UUID(); let generation = receiverGeneration
        let host = selectedAddress
        Task {
            do {
                let result = try await NativeEngine.shared.call(["op": "start_receive", "inbox": MobileFiles.inbox.path, "host": host, "port": 53318])
                guard let handle = result["handle"] as? String else { throw NativeEngine.Failure(message: "未能创建接收任务。") }
                guard receiverGeneration == generation, foreground else {
                    await stopAndRelease(handle)
                    receiverStarting = false; receiverStopping = false
                    return
                }
                receiverHandle = handle
            } catch {
                guard receiverGeneration == generation else {
                    receiverStarting = false; receiverStopping = false; return
                }
                receiverStarting = false; notice = error.localizedDescription
            }
        }
    }
    func stopReceiving() {
        guard !receiverStopping else { return }
        receiverGeneration = UUID()
        receiving = false; receivingTicket = ""; receivingQR = nil
        receiverStopping = receiverHandle != nil || receiverStarting
        if let handle = receiverHandle {
            Task {
                await stopAndRelease(handle)
                receiverHandle = nil; receiverStarting = false; receiverStopping = false
            }
        }
    }
    func copyReceivingCode() {
        guard !receivingTicket.isEmpty else { return }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: receivingTicket]], options: [.localOnly: true])
        notice = "接收码已复制，仅分享给你要接收文件的设备。"
    }
    func clearDestination() { destinationGeneration = UUID(); destination = ""; destinationLabel = "尚未连接发送目标" }
    func pasteDestination() {
        guard let value = UIPasteboard.general.string, !value.isEmpty else {
            notice = "剪贴板中没有接收码。可直接扫描接收设备上的二维码。"; return
        }
        acceptDestination(value)
    }
    func acceptDestination(_ value: String) {
        let ticket = value.trimmingCharacters(in: .whitespacesAndNewlines)
        destinationGeneration = UUID(); let generation = destinationGeneration
        Task {
            do {
                let result = try await NativeEngine.shared.call(["op": "validate_ticket", "ticket": ticket])
                guard destinationGeneration == generation else { return }
                destination = ticket
                destinationLabel = "发送到 \(result["host"] as? String ?? "局域网设备")"
                notice = "已识别接收设备。选择文件并点击发送；对方仍需确认。"
            } catch { if destinationGeneration == generation { notice = error.localizedDescription } }
        }
    }
    func importFiles(_ urls: [URL]) {
        guard !importing else { return }
        importing = true
        Task {
            defer { importing = false }
            for url in urls {
                do {
                    let file = try await Task.detached(priority: .userInitiated) { try MobileFiles.stage(url) }.value
                    staged.append(file)
                } catch { notice = "未能添加 \(url.lastPathComponent)：\(error.localizedDescription)" }
            }
        }
    }
    func recognizeFile(_ url: URL) {
        guard !recognizing else { return }
        recognizing = true
        Task {
            defer { recognizing = false }
            do {
                let ticket = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try InvitationQRCode.recognize(imageAt: url)
                }.value
                acceptDestination(ticket)
            } catch { notice = error.localizedDescription }
        }
    }
    func sendSelected() {
        guard foreground, !destination.isEmpty, !staged.isEmpty, activeID == nil, !startingSend, !senderStopping, canSaveHistory else { return }
        let records = staged.map { SendRecord(source: $0.url, size: $0.size) }
        outgoing.insert(contentsOf: records, at: 0)
        guard save() else { return }
        staged.removeAll()
        pendingIDs = records.map(\.id); batchTicket = destination
        startNext()
    }
    private func startNext() {
        guard foreground, activeID == nil, !startingSend, !senderStopping, !pendingIDs.isEmpty else { return }
        let id = pendingIDs.removeFirst()
        start(id, ticket: batchTicket)
    }
    func resume(_ id: UUID) {
        guard foreground, activeID == nil, !startingSend, !senderStopping, canSaveHistory else { return }
        start(id, ticket: destination)
    }
    private func start(_ id: UUID, ticket: String) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        let journal = MobileFiles.journal(id)
        let existing = FileManager.default.fileExists(atPath: journal.path)
        guard existing || !ticket.isEmpty else { notice = "此任务尚未建立连接，请先扫码识别接收设备再继续。"; return }
        startingSend = true; activeID = id
        outgoing[index].phase = .hashing; outgoing[index].message = nil
        guard save() else { startingSend = false; activeID = nil; return }
        sendGeneration = UUID(); let generation = sendGeneration
        var request: [String: Any] = ["op": "send", "journal": journal.path]
        if !existing { request["source"] = outgoing[index].source; request["ticket"] = ticket }
        Task {
            do {
                let result = try await NativeEngine.shared.call(request)
                guard let handle = result["handle"] as? String else { throw NativeEngine.Failure(message: "未能创建发送任务。") }
                guard sendGeneration == generation, foreground else {
                    await stopAndRelease(handle, senderID: id)
                    finishPausing()
                    return
                }
                senderHandle = handle; startingSend = false
            } catch {
                guard sendGeneration == generation else { finishPausing(); return }
                update(id) { $0.phase = .failed; $0.message = error.localizedDescription }
                activeID = nil; startingSend = false; pendingIDs.removeAll(); _ = save()
            }
        }
    }
    func pauseAll() {
        guard !senderStopping else { return }
        sendGeneration = UUID()
        senderStopping = senderHandle != nil || startingSend
        if let id = activeID { update(id) { if $0.phase != .completed && $0.phase != .failed { $0.phase = .paused } } }
        for id in pendingIDs { update(id) { $0.phase = .paused } }
        pendingIDs.removeAll(); batchTicket = ""
        _ = save()
        if let handle = senderHandle {
            let id = activeID
            Task {
                await stopAndRelease(handle, senderID: id)
                finishPausing()
            }
        } else if !startingSend { finishPausing() }
    }
    private func finishPausing() {
        senderHandle = nil; activeID = nil; startingSend = false; senderStopping = false
        _ = save()
    }
    /// Await the engine's terminal state before a listener or journal can be reused.
    /// This task may suspend with iOS and resumes when the app runs again.
    private func stopAndRelease(_ handle: String, senderID: UUID? = nil) async {
        var stopRequested = false
        while true {
            do {
                if !stopRequested {
                    _ = try await NativeEngine.shared.call(["op": "stop", "handle": handle])
                    stopRequested = true
                }
                let response = try await NativeEngine.shared.call(["op": "poll", "handle": handle])
                if let senderID { try applySendEvents(response, id: senderID); _ = save() }
                if response["finished"] as? Bool == true {
                    _ = try await NativeEngine.shared.call(["op": "release", "handle": handle])
                    return
                }
            } catch { notice = "正在等待任务安全停止：\(error.localizedDescription)" }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
    func decide(_ job: ReceivedTransfer, accept: Bool) {
        guard !decidingIDs.contains(job.id) else { return }
        decidingIDs.insert(job.id)
        Task {
            defer { decidingIDs.remove(job.id) }
            do {
                _ = try await NativeEngine.shared.call(["op": accept ? "approve" : "reject", "inbox": MobileFiles.inbox.path, "id": job.id])
                await refreshIncoming()
            } catch { notice = error.localizedDescription }
        }
    }
    func receivedURL(_ job: ReceivedTransfer) -> URL? {
        guard job.state == "completed", let name = job.final_name, !name.isEmpty,
              URL(fileURLWithPath: name).lastPathComponent == name else { return nil }
        let url = MobileFiles.inbox.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { notice = "文件已被移动或删除，可在“文件”应用中查看 Inbox。"; return nil }
        return url
    }
    private func update(_ id: UUID, _ action: (inout SendRecord) -> Void) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        action(&outgoing[index])
    }
    private func applySendEvents(_ response: [String: Any], id: UUID) throws {
        for value in response["events"] as? [[String: Any]] ?? [] {
            let data = try JSONSerialization.data(withJSONObject: value)
            let event = try JSONDecoder().decode(EngineEvent.self, from: data)
            update(id) {
                if event.event == "stopped", $0.phase != .completed, $0.phase != .failed { $0.phase = .paused }
                else { $0.apply(event) }
            }
        }
    }
    @discardableResult private func save() -> Bool {
        guard canSaveHistory else { return false }
        do { try QueuePersistence.save(outgoing, to: MobileFiles.history); return true }
        catch { canSaveHistory = false; notice = "无法保存任务记录，已停止新任务：\(error.localizedDescription)"; return false }
    }
    private func refreshIncoming() async {
        do {
            let result = try await NativeEngine.shared.call(["op": "jobs", "inbox": MobileFiles.inbox.path])
            let data = try JSONSerialization.data(withJSONObject: result["jobs"] ?? [])
            incoming = try JSONDecoder().decode([ReceivedTransfer].self, from: data)
        } catch { if receiving { notice = error.localizedDescription } }
    }
    private func poll() async {
        guard foreground else { return }
        tickCount += 1
        if tickCount % 12 == 0 {
            let previous = selectedAddress; refreshAddresses()
            if receiving && !addresses.contains(previous) { stopReceiving(); notice = "网络地址已变化，接收已暂停。请重新开启接收并分享新的二维码。" }
        }
        if let handle = receiverHandle, !receiverStopping {
            do {
                let response = try await NativeEngine.shared.call(["op": "poll", "handle": handle])
                guard receiverHandle == handle, !receiverStopping else { return }
                for value in response["events"] as? [[String: Any]] ?? [] {
                    if value["event"] as? String == "ready", let ticket = value["ticket"] as? String {
                        receivingTicket = ticket; receivingQR = try InvitationQRCode.makeImage(ticket)
                        receiving = true; receiverStarting = false
                    }
                    if value["event"] as? String == "error" { notice = value["message"] as? String ?? "接收未完成，请重试。" }
                }
                if response["finished"] as? Bool == true { stopReceiving() }
            } catch { stopReceiving(); notice = error.localizedDescription }
        }
        if let handle = senderHandle, let id = activeID, !senderStopping {
            do {
                let response = try await NativeEngine.shared.call(["op": "poll", "handle": handle])
                guard senderHandle == handle, !senderStopping else { return }
                try applySendEvents(response, id: id)
                _ = save()
                if response["finished"] as? Bool == true {
                    senderHandle = nil; activeID = nil
                    _ = try? await NativeEngine.shared.call(["op": "release", "handle": handle])
                    startNext()
                }
            } catch {
                update(id) { $0.phase = .failed; $0.message = error.localizedDescription }
                pauseAll(); notice = error.localizedDescription
            }
        }
        await refreshIncoming()
    }
}
