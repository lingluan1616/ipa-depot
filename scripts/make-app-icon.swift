#!/usr/bin/env swift
// 程序化生成 App 图标：深灰圆角方底 + 白色「包装盒 + 向下箭头」图形（贝塞尔手绘，不使用系统符号）。
// 用法：swift scripts/make-app-icon.swift App/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                 : "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// 在 1024 坐标系里画图标。
func drawIcon(in ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)
    // 坐标翻转：用左上为原点更直观
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // macOS 图标栅格：824×824 圆角方，居中，留出投影空间
    let body = CGRect(x: 100, y: 92, width: 824, height: 824)
    let radius: CGFloat = 185
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(gray: 0.20, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 底色：深灰，上下极轻微的明度差（非花哨渐变）
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let colors = [CGColor(gray: 0.255, alpha: 1), CGColor(gray: 0.17, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.maxY), options: [])
    // 内描边高光
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: radius - 2, cornerHeight: radius - 2, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // 包装盒（等轴测）：顶面菱形 + 左右两个侧面
    let white = CGColor(gray: 1, alpha: 1)
    let line: CGFloat = 40
    let cx: CGFloat = 512
    let top = CGPoint(x: cx, y: 268)          // 顶面最上点
    let halfW: CGFloat = 236                  // 半宽
    let rise: CGFloat = 132                   // 顶面菱形半高
    let depth: CGFloat = 262                  // 侧面高度
    let left = CGPoint(x: cx - halfW, y: top.y + rise)
    let right = CGPoint(x: cx + halfW, y: top.y + rise)
    let front = CGPoint(x: cx, y: top.y + rise * 2)
    let leftBottom = CGPoint(x: left.x, y: left.y + depth)
    let rightBottom = CGPoint(x: right.x, y: right.y + depth)
    let frontBottom = CGPoint(x: front.x, y: front.y + depth)

    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)

    // 侧面轻微填充，增加体积感
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.10))
    ctx.beginPath()
    ctx.move(to: left); ctx.addLine(to: front); ctx.addLine(to: frontBottom); ctx.addLine(to: leftBottom); ctx.closePath()
    ctx.fillPath()
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.18))
    ctx.beginPath()
    ctx.move(to: front); ctx.addLine(to: right); ctx.addLine(to: rightBottom); ctx.addLine(to: frontBottom); ctx.closePath()
    ctx.fillPath()

    // 外轮廓
    ctx.setStrokeColor(white)
    ctx.setLineWidth(line)
    ctx.beginPath()
    ctx.move(to: top)
    ctx.addLine(to: right)
    ctx.addLine(to: rightBottom)
    ctx.addLine(to: frontBottom)
    ctx.addLine(to: leftBottom)
    ctx.addLine(to: left)
    ctx.closePath()
    ctx.strokePath()
    // 顶面前沿与中间竖棱
    ctx.beginPath()
    ctx.move(to: left); ctx.addLine(to: front); ctx.addLine(to: right)
    ctx.move(to: front); ctx.addLine(to: frontBottom)
    ctx.strokePath()

    // 顶面封箱胶带（从后沿中点到前沿中点的平行线）
    let tapeA = CGPoint(x: (top.x + left.x) / 2, y: (top.y + left.y) / 2)
    let tapeB = CGPoint(x: (right.x + front.x) / 2, y: (right.y + front.y) / 2)
    ctx.setLineWidth(line * 0.75)
    ctx.beginPath()
    ctx.move(to: tapeA); ctx.addLine(to: tapeB)
    ctx.strokePath()

    // 右侧面上的向下箭头（沿侧面方向倾斜，表示「下载入库」）
    let faceCenter = CGPoint(x: (front.x + right.x) / 2, y: (front.y + right.y) / 2 + depth / 2 + 6)
    let arrowLen: CGFloat = 132
    let headW: CGFloat = 62
    let headH: CGFloat = 58
    let shaftTop = CGPoint(x: faceCenter.x, y: faceCenter.y - arrowLen / 2)
    let tip = CGPoint(x: faceCenter.x, y: faceCenter.y + arrowLen / 2)
    ctx.setLineWidth(line * 0.8)
    ctx.beginPath()
    ctx.move(to: shaftTop); ctx.addLine(to: CGPoint(x: tip.x, y: tip.y - 8))
    ctx.move(to: CGPoint(x: tip.x - headW, y: tip.y - headH)); ctx.addLine(to: tip); ctx.addLine(to: CGPoint(x: tip.x + headW, y: tip.y - headH))
    ctx.strokePath()
}

func renderPNG(pixels: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "icon", code: 1)
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    drawIcon(in: ctx, size: CGFloat(pixels))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 2)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 3) }
}

// macOS 规格：16/32/128/256/512 的 1x 与 2x
let specs: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (point, scale) in specs {
    let pixels = point * scale
    let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
    try renderPNG(pixels: pixels, to: outDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(point)x\(point)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try data.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote \(specs.count) icons to \(outDir.path)")
