import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

enum FlowCueMacDownload {
    static let pairingURL = URL(string: "https://flowcue.altn.vision/mac?from=ios-pairing")!
    static let settingsURL = URL(string: "https://flowcue.altn.vision/mac?from=ios-settings")!
}

struct FlowCueMacQRCode: View {
    let url: URL
    var size: CGFloat = 128

    private var isMandarin: Bool { L10n.language == .mandarin }

    var body: some View {
        Group {
            if let image = Self.image(for: url) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.black.opacity(0.45))
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white)
        )
        .accessibilityLabel(isMandarin ? "在 Mac 上打开 FlowCue 的二维码" : "QR code to open FlowCue on your Mac")
    }

    static func image(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
