import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct QRCodeScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error = ""
    @State private var imageImporterPresented = false
    @State private var finished = false
    @State private var importingImage = false
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                QRCodeScannerView(
                    isEnabled: !finished && !importingImage,
                    onCode: acceptCameraCode,
                    onError: { error = $0 }
                )
                .ignoresSafeArea()

                VStack(spacing: 10) {
                    if !error.isEmpty {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.72), in: Capsule())
                    }
                    Button(action: presentImageImporter) {
                        if importingImage {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Import QR Image", systemImage: "photo")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(finished || importingImage)
                    .accessibilityIdentifier("join-request-import-image")
                }
                .padding(.horizontal)
                .padding(.bottom, 18)
            }
            .accessibilityIdentifier("qr-scanner-camera")
            .fileImporter(
                isPresented: $imageImporterPresented,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false,
                onCompletion: handleImageImportResult
            )
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        cancelAndDismiss()
                    }
                }
            }
            .onDisappear(perform: cancelOutstandingWork)
        }
    }

    private func presentImageImporter() {
        guard !finished, !importingImage else { return }
        error = ""
        importingImage = true
        imageImporterPresented = true
    }

    private func handleImageImportResult(_ result: Result<[URL], Error>) {
        guard !finished, importingImage else { return }
        switch result {
        case let .success(urls):
            guard let url = urls.first else {
                resumeCamera(error: "Could not open that image.")
                return
            }
            decodeImportedImage(at: url)
        case .failure:
            resumeCamera(error: "Could not open that image.")
        }
    }

    private func decodeImportedImage(at url: URL) {
        importTask?.cancel()
        importTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                let hasScopedAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if hasScopedAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                guard !Task.isCancelled else {
                    return QrDecodeResult(error: "Cancelled")
                }
                return NativeCoreClient.decodeQrImage(path: url.path)
            }.value
            guard !Task.isCancelled, !finished, importingImage else { return }
            guard result.error.isEmpty,
                  let code = normalizedQrPayload(result.value)
            else {
                resumeCamera(error: "No QR code found in that image.")
                return
            }
            finished = true
            importingImage = false
            onCode(code)
            dismiss()
        }
    }

    private func acceptCameraCode(_ rawCode: String) -> Bool {
        guard !finished, !importingImage, let code = normalizedQrPayload(rawCode) else {
            return false
        }
        finished = true
        importTask?.cancel()
        onCode(code)
        dismiss()
        return true
    }

    private func resumeCamera(error message: String) {
        guard !finished, importingImage else { return }
        importTask = nil
        importingImage = false
        error = message
    }

    private func cancelAndDismiss() {
        cancelOutstandingWork()
        dismiss()
    }

    private func cancelOutstandingWork() {
        guard !finished else { return }
        finished = true
        importingImage = false
        importTask?.cancel()
        importTask = nil
    }
}

private func normalizedQrPayload(_ payload: String?) -> String? {
    guard let code = payload?.trimmingCharacters(in: .whitespacesAndNewlines),
          !code.isEmpty
    else {
        return nil
    }
    return code
}

private struct QRCodeScannerView: UIViewRepresentable {
    let isEnabled: Bool
    let onCode: (String) -> Bool
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onCode: onCode, onError: onError)
    }

    func makeUIView(context: Context) -> ScannerPreviewView {
        let view = ScannerPreviewView()
        context.coordinator.configure(in: view)
        return view
    }

    func updateUIView(_ view: ScannerPreviewView, context: Context) {
        context.coordinator.setEnabled(isEnabled)
        context.coordinator.attachPreview(to: view)
    }

    static func dismantleUIView(_ uiView: ScannerPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Bool
        private let onError: (String) -> Void
        private let sessionQueue = DispatchQueue(label: "fi.siriusbusiness.nvpn.qrscanner")
        private var session: AVCaptureSession?
        private var didConfigure = false
        private var didFinish = false
        private var isEnabled: Bool

        init(
            isEnabled: Bool,
            onCode: @escaping (String) -> Bool,
            onError: @escaping (String) -> Void
        ) {
            self.isEnabled = isEnabled
            self.onCode = onCode
            self.onError = onError
        }

        func setEnabled(_ enabled: Bool) {
            sessionQueue.async {
                self.isEnabled = enabled
            }
        }

        func configure(in view: ScannerPreviewView) {
            guard !didConfigure else {
                attachPreview(to: view)
                return
            }
            didConfigure = true

            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureSession(in: view)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self, weak view] granted in
                    guard let self, let view else { return }
                    DispatchQueue.main.async {
                        granted ? self.configureSession(in: view) : self.onError("Camera access denied.")
                    }
                }
            default:
                onError("Camera access denied.")
            }
        }

        func attachPreview(to view: ScannerPreviewView) {
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
        }

        func stop() {
            sessionQueue.async { [session] in
                if session?.isRunning == true {
                    session?.stopRunning()
                }
            }
        }

        private func configureSession(in view: ScannerPreviewView) {
            let session = AVCaptureSession()
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else {
                onError("Camera scanner unavailable.")
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                onError("Camera scanner unavailable.")
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: sessionQueue)
            output.metadataObjectTypes = [.qr]

            self.session = session
            attachPreview(to: view)
            sessionQueue.async {
                session.startRunning()
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard isEnabled, !didFinish else { return }
            guard let code = normalizedQrPayload(metadataObjects
                .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first(where: { $0.type == .qr })?
                .stringValue)
            else {
                return
            }
            DispatchQueue.main.async {
                if self.onCode(code) {
                    self.sessionQueue.async {
                        self.didFinish = true
                        if self.session?.isRunning == true {
                            self.session?.stopRunning()
                        }
                    }
                }
            }
        }
    }
}

private final class ScannerPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
