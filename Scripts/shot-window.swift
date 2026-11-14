#!/usr/bin/env swift
// 按窗口标题抓图，绕开「窗口在别的 Space / 多显示器」的问题。
// 用法：swift Scripts/shot-window.swift FlowCue /tmp/out.png [--largest]
// 输出：窗口 id（stdout），失败退出码 1。

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("用法: shot-window.swift <窗口属主名> [输出路径]\n".utf8))
    exit(2)
}
let owner = args[1]
let output = args.count >= 3 ? args[2] : nil
// 可选：--size 520x280 精确挑窗口（面板等无标题窗口）
var sizeFilter: (CGFloat, CGFloat)? = nil
if let index = args.firstIndex(of: "--size"), index + 1 < args.count {
    let parts = args[index + 1].lowercased().split(separator: "x")
    if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
        sizeFilter = (CGFloat(w), CGFloat(h))
    }
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("无法读取窗口列表\n".utf8))
    exit(1)
}

struct Candidate { let id: Int; let area: CGFloat }

var candidates: [Candidate] = []
for info in raw {
    guard let name = info[kCGWindowOwnerName as String] as? String,
          name.localizedCaseInsensitiveContains(owner),
          let layer = info[kCGWindowLayer as String] as? Int,
          sizeFilter != nil ? layer >= 0 : layer == 0,
          let bounds = info[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? CGFloat,
          let height = bounds["Height"] as? CGFloat,
          width > 200, height > 200,
          let number = info[kCGWindowNumber as String] as? Int
    else { continue }
    if let filter = sizeFilter {
        guard abs(width - filter.0) <= 24, abs(height - filter.1) <= 24 else { continue }
    }
    candidates.append(Candidate(id: number, area: width * height))
}

guard let target = candidates.max(by: { $0.area < $1.area }) else {
    FileHandle.standardError.write(Data("没有找到「\(owner)」的窗口\n".utf8))
    exit(1)
}

print(target.id)

if let output {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l\(target.id)", output]
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
}
