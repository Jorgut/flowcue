import SwiftUI

extension Color {
    /// `#RRGGBB` / `RRGGBB`
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// 与 macOS 共用同一份 token，仅做 SwiftUI 桥接。
enum FlowCueMobileTheme {
    static func tokens(for scheme: ColorScheme) -> FlowCueTokens {
        FlowCueTokens.tokens(for: scheme == .dark ? .dark : .light)
    }
    static func accent(_ s: ColorScheme) -> Color { Color(hex: tokens(for: s).accent) }
    static func success(_ s: ColorScheme) -> Color { Color(hex: tokens(for: s).success) }
    static func warning(_ s: ColorScheme) -> Color { Color(hex: tokens(for: s).warning) }
    static func failure(_ s: ColorScheme) -> Color { Color(hex: tokens(for: s).failure) }
    static func border(_ s: ColorScheme) -> Color { Color(hex: tokens(for: s).border) }
    static func surface(_ s: ColorScheme) -> Color { Color(hex: tokens(for: s).surface) }
    static func canvas(_ s: ColorScheme) -> Color { Color(hex: tokens(for: s).canvas) }
}

extension UIColor {
    convenience init(flowCueHex hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}
