import AVFoundation
import MultiSyncKit
import SwiftUI

private final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "local.multisync.qr-camera")
    private var active = false
    private var lastFrame = Date.distantPast
    private var recognized: ((String) -> Void)?
    private var feedback: ((String) -> Void)?

    func start(onReady: @escaping () -> Void, onFailure: @escaping (String) -> Void,
               onFeedback: @escaping (String) -> Void, onCode: @escaping (String) -> Void) {
        queue.async {
            guard !self.active else { return }
            self.active = true; self.recognized = onCode; self.feedback = onFeedback
            do {
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                if self.session.inputs.isEmpty {
                    guard let camera = AVCaptureDevice.default(for: .video) else { throw CameraError.unavailable }
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard self.session.canAddInput(input) else { throw CameraError.unavailable }
                    self.session.addInput(input)
                }
                if self.session.outputs.isEmpty {
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    guard self.session.canAddOutput(output) else { throw CameraError.unavailable }
                    self.session.addOutput(output)
                }
                self.session.commitConfiguration()
                self.session.startRunning()
                guard self.session.isRunning else { throw CameraError.unavailable }
                onReady()
            } catch {
                // Balance configuration even when input/output creation fails.
                if self.session.inputs.isEmpty || self.session.outputs.isEmpty { self.session.commitConfiguration() }
                self.active = false
                onFailure(error.localizedDescription)
            }
        }
    }
    func stop() {
        queue.async {
            self.active = false; self.recognized = nil; self.feedback = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active, Date().timeIntervalSince(lastFrame) >= 0.25,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = Date()
        do {
            let code = try InvitationQRCode.recognize(in: buffer)
            active = false
            recognized?(code)
            stop() // schedule after this delegate callback returns
        } catch InvitationQRCode.Failure.noCode {
            // No code in a frame is a normal scanning state.
        } catch {
            feedback?(error.localizedDescription)
        }
    }
    private enum CameraError: LocalizedError {
        case unavailable
        var errorDescription: String? { "摄像头不可用或正被其他应用占用。你也可以关闭此窗口，从二维码图片识别。" }
    }
}

@MainActor
private final class ScannerModel: ObservableObject {
    @Published var running = false
    @Published var starting = false
    @Published var message = "将对方设备的接收二维码放在摄像头前。"
    let camera = CameraCapture()
    private var generation = UUID()

    func start(onCode: @escaping (String) -> Void) {
        guard !starting && !running else { return }
        generation = UUID(); let attempt = generation
        starting = true
        Task {
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
            default: granted = false
            }
            guard generation == attempt else { return }
            guard granted else {
                starting = false
                message = "未获得摄像头权限。可在系统设置的“隐私与安全性 → 摄像头”中允许 MultiSync，或使用二维码图片。"
                return
            }
            camera.start(onReady: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    self.starting = false; self.running = true; self.message = "正在扫描，请保持二维码完整、清晰。"
                }
            }, onFailure: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    self.starting = false; self.running = false; self.message = message
                }
            }, onFeedback: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    self.message = message
                }
            }, onCode: { [weak self] code in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    self.stop(); onCode(code)
                }
            })
        }
    }
    func stop() { generation = UUID(); camera.stop(); running = false; starting = false }
}

private final class CameraPreviewHost: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        preview.videoGravity = .resizeAspectFill; layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() { super.layout(); preview.frame = bounds }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CameraPreviewHost {
        let view = CameraPreviewHost(); view.preview.session = session; return view
    }
    func updateNSView(_ view: CameraPreviewHost, context: Context) {}
}

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = ScannerModel()
    let onCode: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("扫描接收二维码").font(.title2.bold())
            Text("摄像头仅用于本机识别，不录制或上传画面。").foregroundStyle(Theme.muted)
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.canvas)
                if scanner.running {
                    CameraPreview(session: scanner.camera.session).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                } else {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 64, weight: .light)).foregroundStyle(Theme.accent)
                }
            }.frame(height: 320).accessibilityLabel(scanner.running ? "摄像头正在扫描二维码" : "摄像头未开启")
            Text(scanner.message).fixedSize(horizontal: false, vertical: true).frame(minHeight: 42, alignment: .topLeading)
            HStack {
                Button("取消") { scanner.stop(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if scanner.starting { ProgressView().controlSize(.small) }
                if !scanner.running {
                    Button("开启摄像头") {
                        scanner.start { code in onCode(code); dismiss() }
                    }.buttonStyle(.borderedProminent).disabled(scanner.starting)
                }
            }
        }.padding(26).frame(width: 560).onDisappear { scanner.stop() }
    }
}
