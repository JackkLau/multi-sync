import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ImageIO

/// The complete versioned invitation travels in the QR; no credential-bearing web URL is used.
public enum InvitationQRCode {
    public enum Failure: LocalizedError {
        case invalidInvitation, cannotEncode, noCode, ambiguous, unreadableImage, imageTooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidInvitation: return "这不是有效的 MultiSync 局域网接收码，请重新扫描对方的二维码。"
            case .cannotEncode: return "接收邀请过长，无法生成二维码。请使用复制邀请。"
            case .noCode: return "没有识别到二维码。请使用完整、清晰且四周留白的二维码图片。"
            case .ambiguous: return "图片中有多个接收码，请只保留要连接的设备二维码。"
            case .unreadableImage: return "无法读取图片，请选择 PNG、JPEG 或其他系统支持的图片。"
            case .imageTooLarge: return "图片超过 20 MB，请选择二维码截图或缩小后的图片。"
            }
        }
    }

    public static func makeImage(_ invitation: String) throws -> CGImage {
        let value = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Invitation.isPlausible(value) else { throw Failure.invalidInvitation }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage else { throw Failure.cannotEncode }
        let scale = 4, quietZone = 4
        let modules = Int(output.extent.width)
        let size = (modules + quietZone * 2) * scale
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let qr = context.createCGImage(output, from: output.extent),
              let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.cannotEncode }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: size, height: size))
        canvas.interpolationQuality = .none
        canvas.draw(qr, in: CGRect(x: quietZone * scale, y: quietZone * scale, width: modules * scale, height: modules * scale))
        guard let image = canvas.makeImage() else { throw Failure.cannotEncode }
        return image
    }

    public static func selectInvitation(from values: [String]) throws -> String {
        let valid = Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(Invitation.isPlausible))
        guard !valid.isEmpty else { throw Failure.invalidInvitation }
        guard valid.count == 1, let value = valid.first else { throw Failure.ambiguous }
        return value
    }

    private static func recognize(_ image: CIImage) throws -> String {
        // A software Core Image context avoids allocating Vision's hardware-backed pixel buffers.
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: context,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { throw Failure.unreadableImage }
        let values = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        guard !values.isEmpty else { throw Failure.noCode }
        return try selectInvitation(from: values)
    }

    public static func recognize(in image: CGImage) throws -> String {
        try recognize(CIImage(cgImage: image))
    }
    public static func recognize(in buffer: CVPixelBuffer) throws -> String {
        try recognize(CIImage(cvPixelBuffer: buffer))
    }
    public static func recognize(imageAt url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20 * 1024 * 1024 else { throw Failure.imageTooLarge }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { throw Failure.unreadableImage }
        return try recognize(in: image)
    }
}
