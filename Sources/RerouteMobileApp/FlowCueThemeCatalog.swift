import SwiftUI
import UIKit

enum FlowCueThemeGroup: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }
    var title: String { self == .dark ? "Dark" : "Light" }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

struct FlowCueThemeSpec: Identifiable, Hashable {
    let id: String
    let name: String
    let group: FlowCueThemeGroup
    let isPro: Bool
    let background: String
    let foreground: String
    let secondary: String
    let card: String
    let border: String
    let accent: String
    let radius: CGFloat
    let titleFont: String
    let metaFont: String
    let glow: Bool
    let grid: Bool

    var hasBorder: Bool { border != "transparent" }
}

enum FlowCueThemeCatalog {
    static let all: [FlowCueThemeSpec] = [
        FlowCueThemeSpec(id: "neutral", name: "Neutral", group: .dark, isPro: false,
                         background: "#212121", foreground: "#ECECEC", secondary: "#9A9A9A",
                         card: "#2A2A2A", border: "transparent", accent: "#ECECEC",
                         radius: 18, titleFont: "sans", metaFont: "sans", glow: false, grid: false),
        FlowCueThemeSpec(id: "halo", name: "Halo", group: .dark, isPro: true,
                         background: "#191A1F", foreground: "#EDEDF2", secondary: "#9A9AA8",
                         card: "#24252C", border: "#2E2F38", accent: "#A98CFF",
                         radius: 20, titleFont: "sans", metaFont: "sans", glow: true, grid: false),
        FlowCueThemeSpec(id: "editorial", name: "Editorial", group: .dark, isPro: true,
                         background: "#0E1A1D", foreground: "#E7EFEF", secondary: "#8FA6A8",
                         card: "#13262A", border: "#1E3A3F", accent: "#20B8CD",
                         radius: 10, titleFont: "serif", metaFont: "mono", glow: false, grid: false),
        FlowCueThemeSpec(id: "blueprint", name: "Blueprint", group: .dark, isPro: false,
                         background: "#1F1F1F", foreground: "#E8EAED", secondary: "#9AA0A6",
                         card: "#2D2D2D", border: "transparent", accent: "#8AB4F8",
                         radius: 16, titleFont: "sans", metaFont: "sans", glow: false, grid: false),
        FlowCueThemeSpec(id: "mono", name: "Mono", group: .dark, isPro: true,
                         background: "#000000", foreground: "#FFFFFF", secondary: "#8A8A8A",
                         card: "#0A0A0A", border: "#262626", accent: "#FFFFFF",
                         radius: 0, titleFont: "sans", metaFont: "mono", glow: false, grid: false),
        FlowCueThemeSpec(id: "terminal", name: "Terminal", group: .dark, isPro: true,
                         background: "#08090B", foreground: "#E8E8EE", secondary: "#767E88",
                         card: "#0D1014", border: "#1C2026", accent: "#7E84FF",
                         radius: 4, titleFont: "mono", metaFont: "mono", glow: false, grid: true),
        FlowCueThemeSpec(id: "airy", name: "Airy Dark", group: .dark, isPro: false,
                         background: "#101014", foreground: "#F0F0F4", secondary: "#8E8E9A",
                         card: "#181820", border: "#24242E", accent: "#7E84FF",
                         radius: 22, titleFont: "sans", metaFont: "sans", glow: true, grid: false),
        FlowCueThemeSpec(id: "paper", name: "Paper", group: .dark, isPro: true,
                         background: "#0E0E10", foreground: "#EDEBE6", secondary: "#8A8A80",
                         card: "#121214", border: "#232326", accent: "#7E84FF",
                         radius: 2, titleFont: "serif", metaFont: "mono", glow: false, grid: false),
        FlowCueThemeSpec(id: "neutral_light", name: "Neutral Light", group: .light, isPro: false,
                         background: "#FFFFFF", foreground: "#111111", secondary: "#5F5F5F",
                         card: "#F5F5F5", border: "#E6E6E6", accent: "#111111",
                         radius: 18, titleFont: "sans", metaFont: "sans", glow: false, grid: false),
        FlowCueThemeSpec(id: "halo_light", name: "Halo Light", group: .light, isPro: true,
                         background: "#FAF9FE", foreground: "#1B1B22", secondary: "#6B6B7A",
                         card: "#FFFFFF", border: "#E8E4F5", accent: "#6D4AE0",
                         radius: 20, titleFont: "sans", metaFont: "sans", glow: true, grid: false),
        FlowCueThemeSpec(id: "editorial_light", name: "Editorial Light", group: .light, isPro: true,
                         background: "#FAF7EF", foreground: "#16323A", secondary: "#5E7378",
                         card: "#FFFFFF", border: "#E3DED0", accent: "#146C78",
                         radius: 10, titleFont: "serif", metaFont: "mono", glow: false, grid: false),
        FlowCueThemeSpec(id: "blueprint_light", name: "Blueprint Light", group: .light, isPro: true,
                         background: "#FFFFFF", foreground: "#202124", secondary: "#5F6368",
                         card: "#F1F3F4", border: "#DADCE0", accent: "#1A73E8",
                         radius: 16, titleFont: "sans", metaFont: "sans", glow: false, grid: false),
        FlowCueThemeSpec(id: "airy_light", name: "Airy Light", group: .light, isPro: false,
                         background: "#F7F7F5", foreground: "#17171A", secondary: "#6F6F78",
                         card: "#FFFFFF", border: "#E8E6DF", accent: "#5B5BD6",
                         radius: 22, titleFont: "sans", metaFont: "sans", glow: true, grid: false)
    ]

    static func themes(in group: FlowCueThemeGroup) -> [FlowCueThemeSpec] {
        all.filter { $0.group == group }
    }

    static func spec(for id: String) -> FlowCueThemeSpec {
        all.first { $0.id == id } ?? all.first { $0.id == "airy" } ?? all[0]
    }

    @MainActor
    static var defaultID: String {
        FlowCueThemeSelection.defaultID
    }

    @MainActor
    static var defaultSpec: FlowCueThemeSpec {
        spec(for: defaultID)
    }
}

@MainActor
enum FlowCueThemeSelection {
    static let key = "FlowCue.theme"
    static let legacyKey = "FlowCue.appearance"

    static var defaultID: String {
        #if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--flowcue-theme=")
        }) {
            let id = String(argument.dropFirst("--flowcue-theme=".count))
            if FlowCueThemeCatalog.all.contains(where: { $0.id == id }) {
                return id
            }
        }
        #endif
        return UITraitCollection.current.userInterfaceStyle == .dark ? "airy" : "airy_light"
    }

    static func migrateIfNeeded() {
        #if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--flowcue-theme=")
        }) {
            let id = String(argument.dropFirst("--flowcue-theme=".count))
            if FlowCueThemeCatalog.all.contains(where: { $0.id == id }) {
                UserDefaults.standard.set(id, forKey: key)
            }
        }
        #endif
        guard UserDefaults.standard.string(forKey: key) == nil else { return }

        let legacy = UserDefaults.standard.string(forKey: legacyKey) ?? "system"
        let dark: Bool
        switch legacy {
        case "dark": dark = true
        case "light": dark = false
        default: dark = UITraitCollection.current.userInterfaceStyle == .dark
        }
        UserDefaults.standard.set(dark ? "airy" : "airy_light", forKey: key)
    }
}
