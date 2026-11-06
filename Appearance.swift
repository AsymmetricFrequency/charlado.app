import AppKit

enum CharladoMark {
    static let mint = NSColor(srgbRed: 0.54, green: 0.93, blue: 0.78, alpha: 1)
    static let ink = NSColor(srgbRed: 0.06, green: 0.15, blue: 0.15, alpha: 1)

    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 128)
            NSGraphicsContext.saveGraphicsState()
            transform.concat()
            defer { NSGraphicsContext.restoreGraphicsState() }

            let tile = NSBezierPath(roundedRect: NSRect(x: 7, y: 7, width: 114, height: 114),
                                    xRadius: 29, yRadius: 29)
            NSGradient(starting: mint, ending: NSColor(srgbRed: 0.22, green: 0.68,
                                                      blue: 0.59, alpha: 1))?.draw(in: tile, angle: 255)
            ink.setFill()
            let note = NSBezierPath(roundedRect: NSRect(x: 30, y: 34, width: 61, height: 60),
                                    xRadius: 15, yRadius: 15)
            note.fill()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 41, y: 38))
            tail.line(to: NSPoint(x: 40, y: 25))
            tail.line(to: NSPoint(x: 58, y: 36))
            tail.close()
            tail.fill()

            mint.setFill()
            for x in [46, 68] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 63, width: 6, height: 10),
                             xRadius: 3, yRadius: 3).fill()
            }
            mint.setStroke()
            let smile = NSBezierPath()
            smile.move(to: NSPoint(x: 52, y: 54))
            smile.curve(to: NSPoint(x: 68, y: 54), controlPoint1: NSPoint(x: 56, y: 48),
                        controlPoint2: NSPoint(x: 64, y: 48))
            smile.lineWidth = 2.7
            smile.lineCapStyle = .round
            smile.stroke()

            let pencil = NSBezierPath()
            pencil.move(to: NSPoint(x: 74, y: 28))
            pencil.line(to: NSPoint(x: 93, y: 54))
            pencil.line(to: NSPoint(x: 101, y: 48))
            pencil.line(to: NSPoint(x: 83, y: 23))
            pencil.line(to: NSPoint(x: 73, y: 19))
            pencil.close()
            NSColor(srgbRed: 1, green: 0.89, blue: 0.65, alpha: 1).setFill()
            pencil.fill()
            return true
        }
    }

    static func writeIconset(to directory: URL) throws {
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let image = image(size: CGFloat(pixels))
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:])
                else { throw CocoaError(.fileWriteUnknown) }
                let suffix = scale == 2 ? "@2x" : ""
                try png.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }
    }
}

final class DictationIndicator {
    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let symbol = NSImageView()

    init() {
        let bounds = NSRect(x: 0, y: 0, width: 252, height: 62)
        panel = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]

        let glass = NSVisualEffectView(frame: bounds)
        glass.material = .hudWindow
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.state = .active
        glass.blendingMode = .behindWindow
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 20
        glass.layer?.masksToBounds = true
        panel.contentView = glass

        let avatar = NSImageView(image: CharladoMark.image(size: 40))
        avatar.frame = NSRect(x: 12, y: 11, width: 40, height: 40)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 60, y: 33, width: 155, height: 18)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 60, y: 15, width: 155, height: 15)
        symbol.contentTintColor = CharladoMark.mint
        symbol.frame = NSRect(x: 216, y: 22, width: 22, height: 22)
        for view in [avatar, title, detail, symbol] { glass.addSubview(view) }
    }

    func show(processing: Bool, test: Bool = false, fallback: Bool = false) {
        title.stringValue = processing ? "Preparando texto" : "Tomando nota"
        detail.stringValue = processing ? "Transcripción local" :
            (test ? "Prueba de micrófono" : (fallback ? "Suelta el atajo para terminar" : "Suelta Fn para terminar"))
        symbol.image = NSImage(systemSymbolName: processing ? "ellipsis" : "waveform",
                               accessibilityDescription: title.stringValue)
        if !panel.isVisible {
            let pointer = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 24))
            }
            panel.orderFrontRegardless()
        }
    }

    func hide() { panel.orderOut(nil) }
}
