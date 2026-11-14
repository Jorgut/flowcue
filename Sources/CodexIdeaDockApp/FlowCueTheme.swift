import SwiftUI
#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif

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

/// 把 Core 里的语义 token 桥接成 SwiftUI。
enum FlowCueTheme {
    static func tokens(for scheme: ColorScheme) -> FlowCueTokens {
        FlowCueTokens.tokens(for: scheme == .dark ? .dark : .light)
    }

    static func accent(_ scheme: ColorScheme) -> Color { Color(hex: tokens(for: scheme).accent) }
    static func success(_ scheme: ColorScheme) -> Color { Color(hex: tokens(for: scheme).success) }
    static func warning(_ scheme: ColorScheme) -> Color { Color(hex: tokens(for: scheme).warning) }
    static func failure(_ scheme: ColorScheme) -> Color { Color(hex: tokens(for: scheme).failure) }
    static func border(_ scheme: ColorScheme) -> Color { Color(hex: tokens(for: scheme).border) }
    static func textPrimary(_ scheme: ColorScheme) -> Color { Color(hex: tokens(for: scheme).textPrimary) }
    static func textSecondary(_ scheme: ColorScheme) -> Color { Color(hex: tokens(for: scheme).textSecondary) }
}
