#!/usr/bin/env swift
// 设计稿 vs 实现截图，左右并排，带标题。
// 用法：swift Scripts/compare-design.swift <设计稿.png> <截图.png> <输出.png> [左标题] [右标题]

import AppKit

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("用法: compare-design.swift <设计稿> <截图> <输出> [左标题] [右标题]\n".utf8))
    exit(2)
}
let leftPath = args[1], rightPath = args[2], outPath = args[3]
let leftTitle = args.count >= 5 ? args[4] : "设计稿"
let rightTitle = args.count >= 6 ? args[5] : "实现"

guard let left = NSImage(contentsOfFile: leftPath), let right = NSImage(contentsOfFile: rightPath) else {
    FileHandle.standardError.write(Data("无法读取图片\n".utf8))
    exit(1)
}

let targetW: CGFloat = 1200
let leftH = targetW * left.size.height / left.size.width
let rightH = targetW * right.size.height / right.size.width
let header: CGFloat = 44
let gap: CGFloat = 24
let totalH = max(leftH, rightH) + header + gap

let canvas = NSImage(size: NSSize(width: targetW * 2 + gap * 3, height: totalH))
canvas.lockFocus()
NSColor(calibratedRed: 0.043, green: 0.043, blue: 0.063, alpha: 1).setFill()
NSRect(origin: .zero, size: canvas.size).fill()

func draw(_ text: String, at point: NSPoint) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.9, alpha: 1)
    ]
    text.draw(at: point, withAttributes: attrs)
}

draw(leftTitle, at: NSPoint(x: gap, y: canvas.size.height - 34))
draw(rightTitle, at: NSPoint(x: targetW + gap * 2, y: canvas.size.height - 34))

left.draw(in: NSRect(x: gap, y: gap, width: targetW, height: leftH))
right.draw(in: NSRect(x: targetW + gap * 2, y: gap, width: targetW, height: rightH))
canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print(outPath)
