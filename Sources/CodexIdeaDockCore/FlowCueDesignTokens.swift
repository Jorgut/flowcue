import Foundation

/// 双端共用的设计 token。只放语义与数值，不依赖 SwiftUI，
/// 供 macOS / iOS 各自桥接成 Color / CGFloat。
public enum FlowCueAppearance: String, CaseIterable, Codable, Sendable {
    case dark
    case light
}

public struct FlowCueTokens: Sendable, Equatable {
    // 品牌与语义
    public let accent: String          // 主强调色
    public let success: String         // 正常 / 在线
    public let warning: String         // 等待 / 离线
    public let failure: String         // 失败
    // 表面
    public let canvas: String          // 页面底
    public let surface: String         // 卡片
    public let surfaceRaised: String   // 悬浮层 / 面板
    public let border: String          // 描边
    // 文本
    public let textPrimary: String
    public let textSecondary: String
    public let textTertiary: String

    public static let airyDark = FlowCueTokens(
        accent: "#7E84FF",
        success: "#5CD9B8",
        warning: "#F0B429",
        failure: "#FF6B6B",
        canvas: "#101014",
        surface: "#181820",
        surfaceRaised: "#1B1B20",
        border: "#24242E",
        textPrimary: "#F0F0F4",
        textSecondary: "#8E8E9A",
        textTertiary: "#6E6E7A"
    )

    public static let airyLight = FlowCueTokens(
        accent: "#5B5BD6",
        success: "#0F9E7E",
        warning: "#B26B00",
        failure: "#D93025",
        canvas: "#F7F7FA",
        surface: "#FFFFFF",
        surfaceRaised: "#FFFFFF",
        border: "#E3E3EA",
        textPrimary: "#14141A",
        textSecondary: "#5C5C68",
        textTertiary: "#8A8A96"
    )

    public static func tokens(for appearance: FlowCueAppearance) -> FlowCueTokens {
        appearance == .dark ? .airyDark : .airyLight
    }
}

/// 尺寸与节奏：三档圆角、间距刻度、关键控件尺寸。
public enum FlowCueMetrics {
    // 圆角：面板 16 / 卡片 14 / 内嵌 10
    public static let radiusPanel: CGFloat = 16
    public static let radiusCard: CGFloat = 14
    public static let radiusInline: CGFloat = 10
    public static let radiusCapsule: CGFloat = 999

    // 间距刻度（4 的倍数）
    public static let space2: CGFloat = 2
    public static let space4: CGFloat = 4
    public static let space8: CGFloat = 8
    public static let space12: CGFloat = 12
    public static let space16: CGFloat = 16
    public static let space24: CGFloat = 24

    // 关键窗口尺寸（与 docs/UI_DIRECTION.md §10.1 一致）
    public static let capturePanelSize = CGSize(width: 520, height: 280)
    public static let inboxSize = CGSize(width: 980, height: 640)
    public static let settingsSize = CGSize(width: 900, height: 544)

    // 桌面端设置侧栏
    public static let settingsSidebarWidth: CGFloat = 180

    // 行高与控件
    public static let listRowHeight: CGFloat = 52
    public static let controlHeight: CGFloat = 28
    public static let chipHeight: CGFloat = 24
    public static let statusDot: CGFloat = 6
}
