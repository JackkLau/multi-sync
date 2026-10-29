import Darwin
import Foundation

struct StagedFile: Identifiable {
    let id = UUID()
    let url: URL
    let size: UInt64
    var name: String { url.lastPathComponent }
}

enum MobileFiles {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MultiSync", isDirectory: true)
    }
    static var inbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
    }
    static var history: URL { support.appendingPathComponent("outgoing.json") }
    static func journal(_ id: UUID) -> URL { support.appendingPathComponent("Journals/\(id.uuidString).json") }

    static func prepare() throws {
        for path in [support, inbox, support.appendingPathComponent("Journals", isDirectory: true)] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
    }
    static func stage(_ original: URL) throws -> StagedFile {
        let access = original.startAccessingSecurityScopedResource()
        defer { if access { original.stopAccessingSecurityScopedResource() } }
        let directory = support.appendingPathComponent("Sources/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(original.lastPathComponent)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: original, options: .withoutChanges, error: &coordinatorError) { readable in
            do {
                let values = try readable.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else {
                    throw NativeEngine.Failure(message: "请选择普通文件；此版本暂不发送文件夹。")
                }
                try FileManager.default.copyItem(at: readable, to: target)
            } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError as NSError? { throw error }
        let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return StagedFile(url: target, size: UInt64(size))
    }
    static func localAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var addresses: [String: Int] = [:]
        var item: UnsafeMutablePointer<ifaddrs>? = first
        while let current = item {
            defer { item = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let interfaceName = String(cString: current.pointee.ifa_name)
            // A private cellular address is not reachable by peers on the user's Wi-Fi.
            guard !interfaceName.hasPrefix("pdp_ip") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if Invitation.isLocalIPv4(value), !value.hasPrefix("127.") {
                    addresses[value] = interfaceName.hasPrefix("en") || interfaceName.hasPrefix("ap") ? 0 : 1
                }
            }
        }
        return addresses.keys.sorted { (addresses[$0]!, $0) < (addresses[$1]!, $1) }
    }
}
