import CoreGraphics
import Foundation
import XCTest
@testable import MultiSyncKit

final class QRCodeTests: XCTestCase {
    private func invitation(host: String = "192.168.1.8") throws -> String {
        // Roughly the size of a real receiver's DER certificate and capability token.
        let certificate = Data((0..<400).map { UInt8($0 % 256) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let object: [String: Any] = ["version": 1, "host": host, "port": 53318,
                                   "certificate": certificate, "token": String(repeating: "a", count: 64)]
        return "msync1:" + (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func testFullInvitationRoundTripsThroughRenderedQR() throws {
        let value = try invitation()
        let image = try InvitationQRCode.makeImage(value)
        XCTAssertEqual(image.width, image.height)
        XCTAssertGreaterThan(image.width, 300)
        XCTAssertEqual(try InvitationQRCode.recognize(in: image), value)
    }

    func testInvalidAndPublicInvitationsAreNeverEncoded() throws {
        XCTAssertThrowsError(try InvitationQRCode.makeImage("hello"))
        XCTAssertThrowsError(try InvitationQRCode.makeImage(invitation(host: "8.8.8.8")))
    }

    func testNoQRHasActionableError() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 320, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertThrowsError(try InvitationQRCode.recognize(in: image)) { error in
            XCTAssertTrue(error.localizedDescription.contains("二维码"))
        }
    }

    func testMultipleInvitationsAreNotSilentlySelected() throws {
        XCTAssertThrowsError(try InvitationQRCode.selectInvitation(from: [invitation(), invitation(host: "10.0.0.8")]))
        XCTAssertEqual(try InvitationQRCode.selectInvitation(from: ["https://example.com", invitation(), invitation()]), try invitation())
        XCTAssertThrowsError(try InvitationQRCode.selectInvitation(from: ["not an invitation"]))
    }
}
