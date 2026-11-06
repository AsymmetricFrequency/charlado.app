import AppKit

enum CharladoMark {
    static let accent = NSColor(srgbRed: 1, green: 0.81, blue: 0.29, alpha: 1)
    static let ink = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.08, alpha: 1)
    static let paper = NSColor(srgbRed: 0.97, green: 0.96, blue: 0.92, alpha: 1)

    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 128)
            NSGraphicsContext.saveGraphicsState()
            transform.concat()
            defer { NSGraphicsContext.restoreGraphicsState() }

            ink.setFill()
            NSBezierPath(roundedRect: NSRect(x: 10, y: 7, width: 110, height: 110),
                         xRadius: 23, yRadius: 23).fill()
            let face = NSBezierPath(roundedRect: NSRect(x: 8, y: 11, width: 106, height: 110),
                                    xRadius: 22, yRadius: 22)
            accent.setFill()
            face.fill()
            ink.setStroke()
            face.lineWidth = 3
            face.stroke()

            // A voice signal followed by a writing cursor.
            ink.setFill()
            let heights: [CGFloat] = [18, 42, 62, 34]
            for (index, height) in heights.enumerated() {
                let x = 28 + CGFloat(index) * 14
                NSBezierPath(rect: NSRect(x: x, y: 65 - height / 2, width: 7, height: height)).fill()
            }
            NSBezierPath(rect: NSRect(x: 86, y: 47, width: 9, height: 7)).fill()
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
    private let stopButton = NSButton()
    private let pauseButton = NSButton()
    private let markerButton = NSButton()
    private let meter = VoiceMeter()

    init(target: AnyObject, stopAction: Selector, pauseAction: Selector, markerAction: Selector) {
        let bounds = NSRect(x: 0, y: 0, width: 332, height: 62)
        panel = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]

        let surface = NSView(frame: bounds)
        surface.wantsLayer = true
        surface.layer?.backgroundColor = CharladoMark.ink.cgColor
        surface.layer?.borderColor = CharladoMark.accent.cgColor
        surface.layer?.borderWidth = 1
        surface.layer?.cornerRadius = 10
        panel.contentView = surface

        let mark = NSImageView(image: CharladoMark.image(size: 40))
        mark.frame = NSRect(x: 12, y: 11, width: 40, height: 40)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 60, y: 33, width: 155, height: 18)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor(white: 0.76, alpha: 1)
        detail.frame = NSRect(x: 60, y: 15, width: 155, height: 15)
        symbol.contentTintColor = CharladoMark.accent
        symbol.frame = NSRect(x: 296, y: 20, width: 23, height: 23)
        meter.frame = NSRect(x: 214, y: 20, width: 22, height: 22)
        for (index, item) in [(pauseButton, pauseAction, "Pausar reunión", "pause.fill"),
                              (markerButton, markerAction, "Marcar momento", "bookmark"),
                              (stopButton, stopAction, "Terminar reunión", "stop.fill")].enumerated() {
            let (button, action, label, image) = item
            button.image = NSImage(systemSymbolName: image, accessibilityDescription: label)
            button.target = target
            button.action = action
            button.bezelStyle = .circular
            button.frame = NSRect(x: 242 + 27 * index, y: 17, width: 26, height: 28)
            button.isHidden = true
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        for view in [mark, title, detail, symbol, meter, pauseButton, markerButton, stopButton] {
            surface.addSubview(view)
        }
    }

    func show(processing: Bool, test: Bool = false, fallback: Bool = false) {
        panel.ignoresMouseEvents = true
        for button in [pauseButton, markerButton, stopButton] { button.isHidden = true }
        meter.isHidden = processing
        symbol.isHidden = !processing
        title.stringValue = processing ? "Preparando texto" : "Tomando nota"
        detail.stringValue = processing ? "Transcripción local" :
            (test ? "Prueba de micrófono" : (fallback ? "Suelta el atajo para terminar" : "Suelta Fn para terminar"))
        symbol.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Procesando")
        reveal()
    }

    func showMeeting(title: String, detail: String, paused: Bool) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        panel.ignoresMouseEvents = false
        for button in [pauseButton, markerButton, stopButton] { button.isHidden = false }
        let label = paused ? "Reanudar reunión" : "Pausar reunión"
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                    accessibilityDescription: label)
        pauseButton.toolTip = label
        pauseButton.setAccessibilityLabel(label)
        markerButton.isEnabled = !paused
        symbol.isHidden = true
        meter.isHidden = paused
        reveal()
    }

    func updateLevel(_ level: Float) { meter.update(level) }

    private func reveal() {
        if !panel.isVisible {
            let pointer = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 24))
            }
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        meter.update(0)
        panel.orderOut(nil)
    }
}

private final class VoiceMeter: NSView {
    private var level: CGFloat = 0

    func update(_ sample: Float) {
        let target: CGFloat
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            target = 0.38
        } else {
            target = max(0, min(1, CGFloat(sample) * 4))
        }
        let next = level + (target - level) * (target > level ? 0.6 : 0.3)
        guard abs(next - level) > 0.01 else { return }
        level = next
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        CharladoMark.accent.setFill()
        for (index, weight) in [0.45, 1.0, 0.66].enumerated() {
            let height = 4 + 17 * level * weight
            let bar = NSRect(x: 3 + CGFloat(index) * 6, y: (bounds.height - height) / 2, width: 3, height: height)
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
