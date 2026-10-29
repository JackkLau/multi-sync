import XCTest
@testable import MultiSyncKit

final class ModelsTests: XCTestCase {
    func testProgressCompletionAndErrors() throws {
        var record = SendRecord(source: URL(fileURLWithPath: "/tmp/原片.jpg"), size: 100)
        record.apply(try JSONDecoder().decode(EngineEvent.self, from: Data(#"{"event":"progress","offset":60,"size":100}"#.utf8)))
        XCTAssertEqual(record.progress, 0.6)
        XCTAssertEqual(record.phase, .progress)
        record.apply(try JSONDecoder().decode(EngineEvent.self, from: Data(#"{"event":"error","message":"磁盘空间不足"}"#.utf8)))
        XCTAssertEqual(record.phase, .failed)
        XCTAssertEqual(record.message, "磁盘空间不足")
        XCTAssertEqual(record.offset, 60)
    }
    func testRestartKeepsTasksAndPausesUnfinishedWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("queue.json")
        var record = SendRecord(source: URL(fileURLWithPath: "/tmp/source"), size: 50)
        record.phase = .progress; record.offset = 25
        try QueuePersistence.save([record], to: path)
        let loaded = try QueuePersistence.load(from: path)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, record.id)
        XCTAssertEqual(loaded[0].phase, .paused)
        XCTAssertEqual(loaded[0].offset, 25)
        XCTAssertEqual(loaded[0].source, record.source)
        try Data("corrupt".utf8).write(to: path)
        XCTAssertThrowsError(try QueuePersistence.load(from: path))
    }
    func testReceiverStateDecodingAndEmptyFile() throws {
        let raw = #"{"id":"abcd","name":"空文件.txt","size":0,"offset":0,"sha256":"unused","state":"completed","final_name":"空文件.txt"}"#
        let job = try JSONDecoder().decode(ReceivedTransfer.self, from: Data(raw.utf8))
        XCTAssertEqual(job.progress, 1)
        XCTAssertEqual(job.stateLabel, "已接收 · 校验一致")
    }
    func testInvitationValidation() throws {
        XCTAssertFalse(Invitation.isPlausible("http://192.168.1.2"))
        XCTAssertFalse(Invitation.isPlausible("msync1:not-json"))
        XCTAssertFalse(Invitation.isLocalIPv4("8.8.8.8"))
        XCTAssertFalse(Invitation.isLocalIPv4("192.168.1.999"))
        for host in ["10.0.0.2", "192.168.1.2", "172.31.1.2", "127.0.0.1"] { XCTAssertTrue(Invitation.isLocalIPv4(host)) }
        func ticket(host: String) throws -> String {
            let object: [String: Any] = ["version": 1, "host": host, "port": 53318, "certificate":"cert", "token":String(repeating:"a", count:64)]
            return "msync1:" + (try JSONSerialization.data(withJSONObject: object)).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        XCTAssertTrue(Invitation.isPlausible(try ticket(host: "192.168.1.2")))
        XCTAssertFalse(Invitation.isPlausible(try ticket(host: "8.8.8.8")))
    }

    @MainActor
    func testProcessReceivesEventsBeforeExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("engine-fixture.sh")
        try Data("#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"event\":\"waiting\"}' '{\"event\":\"completed\",\"offset\":3,\"size\":3}'\n".utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let done = expectation(description: "engine exited")
        let engine = EngineProcess(); var events: [String] = []
        try engine.start(executable: fixture, arguments: [], input: "invitation", onEvent: { events.append($0.event) }, onExit: { code in
            XCTAssertEqual(code, 0); done.fulfill()
        })
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(events, ["waiting", "completed"])
    }

    @MainActor
    func testProcessFailurePreservesErrorEvent() async throws {
        let runner = EngineProcess()
        let done = expectation(description: "failed process exited")
        var message: String?
        try runner.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '%s\\n' '{\"event\":\"error\",\"message\":\"磁盘空间不足\"}'; exit 7"], onEvent: { message = $0.message }, onExit: {
            XCTAssertEqual($0, 7); done.fulfill()
        })
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(message, "磁盘空间不足")
    }

    @MainActor
    func testPauseTerminatesRunningProcess() async throws {
        let runner = EngineProcess()
        let done = expectation(description: "paused process exited")
        try runner.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '%s\\n' '{\"event\":\"waiting\"}'; exec /bin/sleep 30"], onEvent: { event in
            if event.event == "waiting" { runner.stop() }
        }, onExit: { code in
            XCTAssertNotEqual(code, 0); done.fulfill()
        })
        await fulfillment(of: [done], timeout: 5)
    }
}
