import Foundation

public struct ReceivedTransfer: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let size: UInt64
    public let sha256: String
    public let offset: UInt64
    public let state: String
    public let final_name: String?
    public var progress: Double { size == 0 ? (state == "completed" ? 1 : 0) : min(1, Double(offset) / Double(size)) }
    public var stateLabel: String {
        switch state {
        case "pending": return "等待你确认"
        case "receiving": return "已接受 · 等待或接收数据"
        case "committing": return "正在保存"
        case "completed": return "已接收 · 校验一致"
        case "cancelled": return "已拒绝"
        default: return "未知状态，请升级应用"
        }
    }
}

public struct EngineEvent: Decodable {
    public let event: String
    public let message: String?
    public let ticket: String?
    public let address: String?
    public let name: String?
    public let offset: UInt64?
    public let size: UInt64?
    public let bytes_per_second: Double?
    public let final_name: String?
    public let jobs: [ReceivedTransfer]?
    public let job: ReceivedTransfer?
}

public enum SendPhase: String, Codable {
    case queued, hashing, waiting, progress, verifying, completed, paused, failed
    public var label: String {
        switch self {
        case .queued: return "等待发送"
        case .hashing: return "正在检查源文件"
        case .waiting: return "等待对方接受"
        case .progress: return "正在发送"
        case .verifying: return "对方正在校验并保存"
        case .completed: return "已送达 · 校验一致"
        case .paused: return "已暂停，可继续"
        case .failed: return "未完成，可重试"
        }
    }
}

public struct SendRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public let source: String
    public let name: String
    public var phase: SendPhase
    public var offset: UInt64
    public var size: UInt64
    public var message: String?
    public var finalName: String?
    public var progress: Double { size == 0 ? (phase == .completed ? 1 : 0) : min(1, Double(offset) / Double(size)) }
    public init(source: URL, size: UInt64) {
        id = UUID(); self.source = source.path; name = source.lastPathComponent
        phase = .queued; offset = 0; self.size = size
    }
    public mutating func apply(_ event: EngineEvent) {
        if let phase = SendPhase(rawValue: event.event) { self.phase = phase }
        if event.event == "error" { phase = .failed; message = event.message ?? "传输失败，请检查两台设备的状态" }
        if let size = event.size { self.size = size }
        if let offset = event.offset { self.offset = offset }
        if let name = event.final_name { finalName = name }
    }
}

public enum QueuePersistence {
    public static func load(from path: URL) throws -> [SendRecord] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        var records = try JSONDecoder().decode([SendRecord].self, from: Data(contentsOf: path))
        for index in records.indices where records[index].phase != .completed && records[index].phase != .failed {
            records[index].phase = .paused
        }
        return records
    }
    public static func save(_ records: [SendRecord], to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(records).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}

public enum Invitation {
    /// Frontend feedback only. The Rust engine performs authoritative validation and TLS trust.
    public static func isPlausible(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("msync1:"), value.utf8.count <= 16384 else { return false }
        var payload = String(value.dropFirst(7)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1,
              let host = object["host"] as? String, isLocalIPv4(host),
              let port = object["port"] as? Int, (1...65535).contains(port),
              let certificate = object["certificate"] as? String, !certificate.isEmpty,
              let token = object["token"] as? String, token.utf8.count == 64,
              token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return false }
        return true
    }
    public static func isLocalIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let parts = components.compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
    }
}
