import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision

struct QRCodeScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error = ""
    @State private var imageImporterPresented = false
    @State private var importingImage = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                QRCodeScannerView(
                    onCode: { code in
                        completeQrCode(code)
                    },
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
                    Button {
                        imageImporterPresented = true
                    } label: {
                        if importingImage {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Import QR Image", systemImage: "photo")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importingImage)
                    .accessibilityIdentifier("join-request-import-image")
                }
                .padding(.horizontal)
                .padding(.bottom, 18)
            }
            .accessibilityIdentifier("qr-scanner-camera")
            .fileImporter(
                isPresented: $imageImporterPresented,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    importQrCode(from: url)
                case .failure:
                    error = "Could not open that image."
                }
            }
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func completeQrCode(_ code: String) {
        onCode(code)
        dismiss()
    }

    private func importQrCode(from url: URL) {
        importingImage = true
        error = ""
        Task {
            defer {
                importingImage = false
            }
            do {
                let code = try await Task.detached {
                    let hasScopedAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasScopedAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    return try QRCodeImageDecoder.decode(data: Data(contentsOf: url))
                }.value
                completeQrCode(code)
            } catch {
                self.error = "No QR code found in that image."
            }
        }
    }
}

enum QRCodeImageDecoder {
    enum DecodeError: Error {
        case invalidImage
        case qrCodeMissing
    }

    static func decode(data: Data) throws -> String {
        guard let image = UIImage(data: data)?.cgImage else {
            throw DecodeError.invalidImage
        }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])

        let payload = request.results?
            .first(where: { $0.symbology == .qr })?
            .payloadStringValue
        guard let code = normalizedQrPayload(payload) else {
            throw DecodeError.qrCodeMissing
        }
        return code
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
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onError: onError)
    }

    func makeUIView(context: Context) -> ScannerPreviewView {
        let view = ScannerPreviewView()
        context.coordinator.configure(in: view)
        return view
    }

    func updateUIView(_ view: ScannerPreviewView, context: Context) {
        context.coordinator.attachPreview(to: view)
    }

    static func dismantleUIView(_ uiView: ScannerPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        private let onError: (String) -> Void
        private let sessionQueue = DispatchQueue(label: "fi.siriusbusiness.nvpn.qrscanner")
        private var session: AVCaptureSession?
        private var didConfigure = false
        private var didFinish = false

        init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onCode = onCode
            self.onError = onError
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
            guard !didFinish else { return }
            guard let code = normalizedQrPayload(metadataObjects
                .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first(where: { $0.type == .qr })?
                .stringValue)
            else {
                return
            }
            didFinish = true
            session?.stopRunning()
            DispatchQueue.main.async {
                self.onCode(code)
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
