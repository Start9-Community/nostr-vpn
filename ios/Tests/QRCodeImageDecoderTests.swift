import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import XCTest
@testable import NostrVpnIos

final class QRCodeImageDecoderTests: XCTestCase {
    func testDecodesQrImageThroughProductionDecoder() throws {
        let payload = "nvpn://join-request/test-production-image-decoder"
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(payload.utf8)
        generator.correctionLevel = "M"

        let scaled = try XCTUnwrap(generator.outputImage).transformed(
            by: CGAffineTransform(scaleX: 8, y: 8)
        )
        let cgImage = try XCTUnwrap(CIContext().createCGImage(scaled, from: scaled.extent))
        let data = try XCTUnwrap(UIImage(cgImage: cgImage).pngData())

        XCTAssertEqual(try QRCodeImageDecoder.decode(data: data), payload)
    }

    func testRejectsImageWithoutQrCode() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let data = renderer.pngData { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }

        XCTAssertThrowsError(try QRCodeImageDecoder.decode(data: data)) { error in
            guard case QRCodeImageDecoder.DecodeError.qrCodeMissing = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
