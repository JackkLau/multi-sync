import Foundation

/// Serialization keeps SQLite decisions and handle operations off the main thread.
actor NativeEngine {
    static let shared = NativeEngine()
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    func call(_ request: [String: Any]) throws -> [String: Any] {
        let bytes = try JSONSerialization.data(withJSONObject: request)
        guard let json = String(data: bytes, encoding: .utf8),
              let pointer = json.withCString({ multisync_call($0) }) else {
            throw Failure(message: "传输引擎没有返回结果，请重试。")
        }
        defer { multisync_free(pointer) }
        let response = Data(String(cString: pointer).utf8)
        guard let result = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw Failure(message: "传输引擎返回了无法识别的数据。")
        }
        guard result["ok"] as? Bool == true else {
            throw Failure(message: result["error"] as? String ?? "操作未完成，请重试。")
        }
        return result
    }
}
