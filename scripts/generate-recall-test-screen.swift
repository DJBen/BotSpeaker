import AppKit
let context = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.16, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1280, height: 720)).fill()
func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor = .white) {
    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color])
}
label("BotSpeaker", 80, 570, 44, NSColor(calibratedRed: 0.35, green: 0.8, blue: 1, alpha: 1))
label("SCREEN SHARE TEST", 80, 440, 76)
label("A remote bot is presenting this screen.", 80, 330, 46)
for (index, color) in [NSColor.systemCyan, .systemGreen, .systemYellow, .systemOrange, .systemPink].enumerated() {
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: 80 + index * 224, y: 135, width: 200, height: 100), xRadius: 12, yRadius: 12).fill()
}
label("1280 × 720   •   Recall.ai", 80, 65, 28, .lightGray)
NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("Generated test card: \(data.count) bytes")
