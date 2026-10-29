import AVFoundation
import SwiftUI
import UIKit

private final class CapturePipeline: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "local.multisync.ios.camera")
    private var onCode: ((String) -> Void)?
    private var onFeedback: ((String) -> Void)?
    private var active = false

    func start(ready: @escaping () -> Void, failure: @escaping (String) -> Void,
               feedback: @escaping (String) -> Void, recognized: @escaping (String) -> Void) {
        queue.async {
            guard !self.active else { return }
            self.active = true; self.onCode = recognized; self.onFeedback = feedback
            var configuring = false
            do {
                self.session.beginConfiguration(); configuring = true
                self.session.sessionPreset = .high
                if self.session.inputs.isEmpty {
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                            ?? AVCaptureDevice.default(for: .video) else {
                        throw NativeEngine.Failure(message: "此设备没有可用摄像头，可使用二维码图片。")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else { throw NativeEngine.Failure(message: "摄像头正忙，请关闭其他相机应用后重试。") }
                    self.session.addInput(input)
                }
                if self.session.outputs.isEmpty {
                    let output = AVCaptureMetadataOutput()
                    guard self.session.canAddOutput(output) else { throw NativeEngine.Failure(message: "无法启动扫码，可改用二维码图片。") }
                    self.session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: self.queue)
                    guard output.availableMetadataObjectTypes.contains(.qr) else { throw NativeEngine.Failure(message: "此摄像头不支持二维码识别。") }
                    output.metadataObjectTypes = [.qr]
                }
                self.session.commitConfiguration(); configuring = false
                self.session.startRunning()
                guard self.session.isRunning else { throw NativeEngine.Failure(message: "摄像头未能开启，请重试或使用二维码图片。") }
                ready()
            } catch {
                if configuring {
                    for output in self.session.outputs { self.session.removeOutput(output) }
                    self.session.commitConfiguration()
                }
                self.active = false; self.onCode = nil; self.onFeedback = nil
                if self.session.isRunning { self.session.stopRunning() }
                failure(error.localizedDescription)
            }
        }
    }
    func stop() {
        queue.async {
            self.active = false; self.onCode = nil; self.onFeedback = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard active else { return }
        let values = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        guard !values.isEmpty else { return }
        do {
            let value = try InvitationQRCode.selectInvitation(from: values)
            active = false; onCode?(value); stop()
        } catch { onFeedback?(error.localizedDescription) }
    }
}

@MainActor
private final class ScannerState: ObservableObject {
    @Published var running = false
    @Published var starting = false
    @Published var message = "将接收设备的二维码完整放入画面。"
    let pipeline = CapturePipeline()
    private var generation = UUID()
    func start(_ recognized: @escaping (String) -> Void) {
        guard !starting, !running else { return }
        generation = UUID(); let attempt = generation; starting = true
        Task {
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard generation == attempt else { return }
            guard allowed else {
                starting = false
                message = "未获得摄像头权限。可在系统设置中允许 MultiSync 使用摄像头，或返回使用二维码图片。"
                return
            }
            pipeline.start(ready: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    self.starting = false; self.running = true
                }
            }, failure: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    self.starting = false; self.running = false; self.message = message
                }
            }, feedback: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    self.message = message
                }
            }, recognized: { [weak self] code in
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    self.stop(); recognized(code)
                }
            })
        }
    }
    func stop() { generation = UUID(); pipeline.stop(); running = false; starting = false }
}

private final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface(); view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill; return view
    }
    func updateUIView(_ view: PreviewSurface, context: Context) {}
}
struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var scanner = ScannerState()
    let onCode: (String) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
              VStack(spacing: 22) {
                Text("镜头仅在本机识别二维码，不录制或上传画面。")
                    .foregroundStyle(.secondary)
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.06))
                    if scanner.running {
                        CameraPreview(session: scanner.pipeline.session).clipShape(RoundedRectangle(cornerRadius: 20))
                    } else {
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 76)).foregroundStyle(MobileTheme.accent)
                    }
                }.frame(maxWidth: 480).aspectRatio(1, contentMode: .fit)
                    .accessibilityLabel(scanner.running ? "摄像头正在扫描" : "摄像头未开启")
                Text(scanner.message).frame(maxWidth: .infinity, alignment: .leading)
                if scanner.starting { ProgressView("正在开启摄像头") }
                if !scanner.running {
                    Button("开启摄像头") { scanner.start { onCode($0); dismiss() } }
                        .buttonStyle(.borderedProminent).disabled(scanner.starting)
                }
              }.padding(24)
            }.navigationTitle("扫码连接").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { scanner.stop(); dismiss() } } }
        }.onDisappear { scanner.stop() }
            .onChange(of: scenePhase) { phase in if phase == .background { scanner.stop() } }
    }
}
