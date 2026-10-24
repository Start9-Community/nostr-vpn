import AVFoundation
import AppKit
import SwiftUI
import Vision

struct QRCodeScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error = ""

    var body: some View {
        VStack(spacing: 12) {
            QRCodeScannerView(
                onCode: { code in
                    onCode(code)
                    dismiss()
                },
                onError: { message in
                    error = message
                }
            )
            .frame(width: 460, height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Text(error)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 500)
    }
}

struct QRCodeScannerView: NSViewRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onError: onError)
    }

    func makeNSView(context: Context) -> ScannerPreviewView {
        let view = ScannerPreviewView()
        context.coordinator.start(in: view)
        return view
    }

    func updateNSView(_ nsView: ScannerPreviewView, context: Context) {}

    static func dismantleNSView(_ nsView: ScannerPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let onCode: (String) -> Void
        private let onError: (String) -> Void
        private let sessionQueue = DispatchQueue(label: "fi.siriusbusiness.nvpn.qrscanner")
        private var session: AVCaptureSession?
        private var didEmitCode = false
        // Only touched on the main thread; session work stays on sessionQueue.
        private var isActive = false
        private lazy var barcodeRequest: VNDetectBarcodesRequest = {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            return request
        }()

        init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onCode = onCode
            self.onError = onError
        }

        func start(in view: ScannerPreviewView) {
            isActive = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configure(in: view)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self, weak view] granted in
                    DispatchQueue.main.async {
                        guard let self, self.isActive, let view else {
                            return
                        }
                        granted ? self.configure(in: view) : self.onError("Camera access denied.")
                    }
                }
            default:
                onError("Camera access denied.")
            }
        }

        func stop() {
            isActive = false
            sessionQueue.async { [self] in
                if session?.isRunning == true {
                    session?.stopRunning()
                }
                session = nil
            }
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard !didEmitCode,
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: imageBuffer, orientation: .up)
            guard (try? handler.perform([barcodeRequest])) != nil,
                  let value = barcodeRequest.results?
                    .first(where: { $0.symbology == .qr })?
                    .payloadStringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return
            }

            didEmitCode = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive else {
                    return
                }
                self.stop()
                self.onCode(value)
            }
        }

        private func configure(in view: ScannerPreviewView) {
            sessionQueue.async { [weak self, weak view] in
                guard let self, let nextSession = self.makeSession() else { return }
                self.session = nextSession
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, self.isActive, let view else { return }
                    view.attach(session: nextSession)
                    self.sessionQueue.async { [self] in
                        guard self.session === nextSession else { return }
                        nextSession.startRunning()
                    }
                }
            }
        }

        private func reportError(_ message: String) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive else { return }
                self.onError(message)
            }
        }

        private func makeSession() -> AVCaptureSession? {
            guard let device = AVCaptureDevice.default(for: .video) else {
                reportError("No camera found.")
                return nil
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                let nextSession = AVCaptureSession()
                nextSession.beginConfiguration()
                guard nextSession.canAddInput(input), nextSession.canAddOutput(output) else {
                    nextSession.commitConfiguration()
                    reportError("Camera scanner unavailable.")
                    return nil
                }
                nextSession.addInput(input)
#if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    // QR recognition does not use Cinematic Video. AVFoundation throws an
                    // Objective-C exception if QR-only metadata is selected while this is on.
                    input.isCinematicVideoCaptureEnabled = false
                }
#endif
                nextSession.addOutput(output)
                nextSession.commitConfiguration()
                output.setSampleBufferDelegate(self, queue: sessionQueue)
                return nextSession
            } catch {
                reportError(error.localizedDescription)
                return nil
            }
        }
    }
}

final class ScannerPreviewView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    func attach(session: AVCaptureSession) {
        wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.layer = layer
        previewLayer = layer
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}
