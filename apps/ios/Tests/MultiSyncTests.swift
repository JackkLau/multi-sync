import CoreGraphics
import Foundation
import XCTest
@testable import MultiSync

final class MultiSyncTests: XCTestCase {
    private func stopAndRelease(_ handle: String) async throws {
        let engine = NativeEngine.shared
        _ = try await engine.call(["op": "stop", "handle": handle])
        for _ in 0..<200 {
            let result = try await engine.call(["op": "poll", "handle": handle])
            if result["finished"] as? Bool == true {
                _ = try await engine.call(["op": "release", "handle": handle])
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Native task did not reach its terminal state after stop")
    }
    private func invitation(host: String = "192.168.1.8") throws -> String {
        let certificate = Data((0..<400).map { UInt8($0 % 256) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let object: [String: Any] = ["version": 1, "host": host, "port": 53318, "certificate": certificate, "token": String(repeating: "b", count: 64)]
        return "msync1:" + (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func testCompleteInvitationRoundTrip() throws {
        let code = try invitation()
        XCTAssertEqual(try InvitationQRCode.recognize(in: InvitationQRCode.makeImage(code)), code)
    }
    func testRejectsPublicAndAmbiguousCodes() throws {
        XCTAssertFalse(Invitation.isPlausible(try invitation(host: "8.8.8.8")))
        XCTAssertThrowsError(try InvitationQRCode.selectInvitation(from: [invitation(), invitation(host: "10.0.0.4")]))
        XCTAssertThrowsError(try InvitationQRCode.makeImage("https://example.com"))
    }
    func testRestartPreservesQueueAndSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.txt")
        try Data("keep original".utf8).write(to: source)
        var record = SendRecord(source: source, size: 13)
        record.phase = .progress; record.offset = 5
        let history = folder.appendingPathComponent("history.json")
        try QueuePersistence.save([record], to: history)
        let reloaded = try QueuePersistence.load(from: history)
        XCTAssertEqual(reloaded[0].id, record.id)
        XCTAssertEqual(reloaded[0].phase, .paused)
        XCTAssertEqual(reloaded[0].offset, 5)
        XCTAssertEqual(try Data(contentsOf: source), Data("keep original".utf8))
    }
    func testBridgeRejectsMalformedAndPublicTickets() async throws {
        do {
            _ = try await NativeEngine.shared.call(["op": "validate_ticket", "ticket": "not an invitation"])
            XCTFail("Invalid invitation was accepted")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        do {
            _ = try await NativeEngine.shared.call(["op": "validate_ticket", "ticket": invitation(host: "8.8.8.8")])
            XCTFail("Public destination was accepted")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testNativeBridgeTransfersFileWithExplicitAcceptance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = directory.appendingPathComponent("Inbox")
        let source = directory.appendingPathComponent("original.bin")
        let bytes = Data((0..<(1024 * 1024 + 91)).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let engine = NativeEngine.shared
        var receiver: String?
        var sender: String?
        do {
            let started = try await engine.call(["op": "start_receive", "inbox": inbox.path, "host": "127.0.0.1", "port": 0])
            receiver = try XCTUnwrap(started["handle"] as? String)
            var ticket: String?
            for _ in 0..<100 {
                let polled = try await engine.call(["op": "poll", "handle": receiver!])
                for event in polled["events"] as? [[String: Any]] ?? [] {
                    if event["event"] as? String == "error" { XCTFail(event["message"] as? String ?? "receiver error") }
                    if event["event"] as? String == "ready" { ticket = event["ticket"] as? String }
                }
                if ticket != nil { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let invitation = try XCTUnwrap(ticket)
            XCTAssertEqual(try InvitationQRCode.recognize(in: InvitationQRCode.makeImage(invitation)), invitation)
            let send = try await engine.call(["op": "send", "source": source.path,
                "journal": directory.appendingPathComponent("job.json").path, "ticket": invitation])
            sender = try XCTUnwrap(send["handle"] as? String)
            var accepted = false
            var completedName: String?
            for _ in 0..<200 {
                let jobs = try await engine.call(["op": "jobs", "inbox": inbox.path])
                for job in jobs["jobs"] as? [[String: Any]] ?? [] where job["state"] as? String == "pending" {
                    XCTAssertEqual(job["offset"] as? Int, 0)
                    _ = try await engine.call(["op": "approve", "inbox": inbox.path, "id": job["id"] as! String])
                    accepted = true
                }
                let polled = try await engine.call(["op": "poll", "handle": sender!])
                for event in polled["events"] as? [[String: Any]] ?? [] {
                    if event["event"] as? String == "error" { XCTFail(event["message"] as? String ?? "sender error") }
                    if event["event"] as? String == "completed" { completedName = event["final_name"] as? String }
                }
                if completedName != nil { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(accepted, "Each new file needs local receiver approval")
            let name = try XCTUnwrap(completedName)
            XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent(name)), bytes)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        } catch {
            if let sender { try? await stopAndRelease(sender) }
            if let receiver { try? await stopAndRelease(receiver) }
            throw error
        }
        if let sender { try await stopAndRelease(sender) }
        if let receiver { try await stopAndRelease(receiver) }
    }
}
