import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import OSLog
import Speech

private let diagnostics = Logger(subsystem: "local.agentbot.charlado", category: "dictation")

func clean(_ transcript: String) -> String {
    let text = transcript.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard let first = text.first else { return "" }
    return first.uppercased() + text.dropFirst()
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

struct Destination {
    let pid: pid_t
    let element: AXUIElement
    let selection: CFTypeRef?

    static func current() -> Destination? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
              ?? attribute(appElement, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier
        else { return nil }
        guard let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole
        else { return nil }
        return Destination(pid: app.processIdentifier, element: element,
                           selection: attribute(element, kAXSelectedTextRangeAttribute))
    }

    func requestPaste() -> Bool {
        guard stillFocused(), CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func stillFocused() -> Bool {
        guard let current = Self.current(), pid == current.pid, CFEqual(element, current.element)
        else { return false }
        guard let selection else { return true }
        guard let currentSelection = current.selection else { return false }
        return CFEqual(selection, currentSelection)
    }
}

@discardableResult
func copyToClipboard(_ text: String) -> Bool {
    let board = NSPasteboard.general
    board.clearContents()
    return board.setString(text, forType: .string)
}

enum LocalSpeech {
    static func prepare() async throws -> Locale {
        for identifier in ["es-CO", "es-MX", "es-ES", "es-US"] {
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
                let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                return locale
            }
        }
        throw NSError(domain: "CharladoSpeech", code: 1)
    }

    static func transcribe(_ url: URL, locale: Locale) async throws -> String {
        let paddedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: paddedURL) }
        try appendTrailingSilence(from: url, to: paddedURL)
        let audio = try AVAudioFile(forReading: paddedURL)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let output: String = collect(transcriber)
        do {
            try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
            return try await output
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func appendTrailingSilence(from source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let output = try AVAudioFile(forWriting: destination, settings: format.settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let silenceFrames = AVAudioFrameCount(format.sampleRate * 1.2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: silenceFrames) else {
            throw NSError(domain: "CharladoSpeech", code: 2)
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }

        // Give the recognizer room to finalize the word spoken just before release.
        buffer.frameLength = silenceFrames
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
        }
        try output.write(from: buffer)
    }

    private static func collect(_ transcriber: SpeechTranscriber) async throws -> String {
        var fragments: [String] = []
        for try await result in transcriber.results {
            if result.isFinal { fragments.append(String(result.text.characters)) }
        }
        return clean(fragments.joined(separator: " "))
    }
}

final class Dictation: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var speechLocale: Locale?
    private var preparingSpeech = false
    private var preparationFailed = false
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let message = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var fnTap: CFMachPort?
    private var fallbackKey: EventHotKeyRef?
    private var fallbackHandler: EventHandlerRef?
    private var fnDown = false
    private var fallbackDown = false
    private var setupWindow: NSWindow?
    private lazy var indicator = DictationIndicator()
    private let fnStatus = NSTextField(labelWithString: "Fn: esperando una pulsación")
    private let setupStatus = NSTextField(wrappingLabelWithString: "")
    private let testResult = NSTextField(wrappingLabelWithString: "El texto de prueba aparecerá aquí.")
    private lazy var testButton = NSButton(title: "Probar micrófono", target: self, action: #selector(testMicrophone))
    private var session: Recording?
    private var lastText = ""
    private var held = false

    private final class Recording {
        let engine = AVAudioEngine()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let destination: Destination?
        let isTest: Bool
        var task: Task<Void, Never>?
        var latest = ""
        var stopped = false

        init(isTest: Bool) {
            self.isTest = isTest
            destination = !isTest && AXIsProcessTrusted() ? Destination.current() : nil
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.addItem(message)
        menu.addItem(NSMenuItem(title: "Abrir Charlado", action: #selector(openSetup), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Configurar permisos", action: #selector(permissions), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copiar último dictado", action: #selector(copyLast), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        menu.items.last?.target = NSApp
        menu.delegate = self
        status.menu = menu
        registerFallback()
        openSetup()
        prepareSpeech()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSetup()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if session == nil { refreshSetup() }
    }

    @objc private func openSetup() {
        if setupWindow == nil {
            let title = NSTextField(labelWithString: "Charlado")
            title.font = .systemFont(ofSize: 28, weight: .semibold)
            let subtitle = NSTextField(labelWithString: "Dictado local en español")
            subtitle.font = .systemFont(ofSize: 13)
            subtitle.textColor = .secondaryLabelColor
            let brand = NSStackView(views: [title, subtitle])
            brand.orientation = .vertical
            brand.alignment = .leading
            brand.spacing = 2
            let avatar = NSImageView(image: CharladoMark.image(size: 64))
            let header = NSStackView(views: [avatar, brand])
            header.spacing = 12
            let instructions = NSTextField(wrappingLabelWithString:
                "Mantén pulsada Fn para hablar. Suéltala para pegar el texto donde está el cursor. También puedes usar Control + Opción + D.")
            instructions.font = .systemFont(ofSize: 14)
            setupStatus.font = .systemFont(ofSize: 13, weight: .semibold)
            fnStatus.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            fnStatus.textColor = .secondaryLabelColor
            let button = NSButton(title: "Configurar permisos", target: self, action: #selector(permissions))
            let background = NSButton(title: "Seguir en segundo plano", target: self,
                                      action: #selector(hideSetup))
            background.bezelStyle = .rounded
            background.controlSize = .large
            background.bezelColor = CharladoMark.mint
            background.setAccessibilityHelp("Oculta la ventana y mantiene activo el atajo de dictado.")
            let actions = NSStackView(views: [background, button])
            actions.alignment = .centerY
            actions.spacing = 12
            let divider = NSBox()
            divider.boxType = .separator
            let stack = NSStackView(views: [header, instructions, divider, setupStatus, fnStatus,
                                            actions, testButton, testResult])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 16
            stack.translatesAutoresizingMaskIntoConstraints = false

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Charlado"
            window.delegate = self
            window.isReleasedWhenClosed = false
            if let content = window.contentView {
                content.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                    stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                    stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                    avatar.widthAnchor.constraint(equalToConstant: 64),
                    avatar.heightAnchor.constraint(equalToConstant: 64),
                    divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
                    instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
                    setupStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
                    testResult.widthAnchor.constraint(equalTo: stack.widthAnchor)
                ])
            }
            window.center()
            setupWindow = window
        }
        if session == nil { refreshSetup() }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func hideSetup() {
        setupWindow?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideSetup()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func menuWillOpen(_ menu: NSMenu) {
        if fnTap == nil { refreshSetup() }
    }

    private func registerFallback() {
        let events = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        guard InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x43484152, identifier.id == 1
            else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<Dictation>.fromOpaque(context).takeUnretainedValue()
            app.updateShortcut(fn: nil, fallback: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }, events.count, events, Unmanaged.passUnretained(self).toOpaque(), &fallbackHandler) == noErr
        else { return }
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: 0x43484152, id: 1),
                            GetApplicationEventTarget(), 0, &fallbackKey)
    }

    private func updateShortcut(fn: Bool?, fallback: Bool? = nil) {
        let wasDown = fnDown || fallbackDown
        if let fn, fn != fnDown {
            fnDown = fn
            fnStatus.stringValue = fn ? "Fn: pulsación detectada" : "Fn: pulsación y liberación detectadas"
            diagnostics.notice("Fn \(fn ? "pulsada" : "liberada", privacy: .public), ventana \(self.setupWindow?.isVisible == true ? "visible" : "oculta", privacy: .public)")
        }
        if let fallback { fallbackDown = fallback }
        let isDown = fnDown || fallbackDown
        guard wasDown != isDown else { return }
        if isDown { press() } else { release() }
    }

    private func prepareSpeech() {
        guard speechLocale == nil, !preparingSpeech else { return }
        preparingSpeech = true
        preparationFailed = false
        refreshSetup()
        Task { @MainActor in
            defer {
                preparingSpeech = false
                refreshSetup()
            }
            do { speechLocale = try await LocalSpeech.prepare() }
            catch {
                preparationFailed = true
                NSLog("Charlado: error preparando español: %@", String(describing: error))
            }
        }
    }

    private func refreshSetup() {
        if preparingSpeech {
            show("Preparando el modelo local de español…", icon: "…")
            return
        }
        if preparationFailed {
            show("No se pudo preparar español. Pulsa Probar micrófono para reintentar", icon: "🎙!")
            return
        }
        guard CGPreflightListenEventAccess() else {
            show("Fn requiere Monitorización de entrada. Puedes usar Control + Opción + D o Probar micrófono", icon: "🎙!")
            return
        }
        if fnTap == nil {
            let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let app = Unmanaged<Dictation>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        DispatchQueue.main.async { app.recoverFnMonitor() }
                    } else if type == .flagsChanged {
                        let pressed = event.flags.contains(.maskSecondaryFn)
                        DispatchQueue.main.async {
                            app.updateShortcut(fn: pressed)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque()
            ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
                show("Reabre Charlado tras habilitar Monitorización de entrada", icon: "🎙!")
                return
            }
            fnTap = tap
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           SFSpeechRecognizer.authorizationStatus() == .authorized, AXIsProcessTrusted() {
            show("Mantén pulsada Fn para dictar")
        } else {
            show("Abre Configurar permisos para completar la configuración", icon: "🎙!")
        }
    }

    private func recoverFnMonitor() {
        if fnDown {
            fnDown = false
            if !fallbackDown {
                held = false
                if let session, !session.stopped, !session.isTest { finish(session, interrupted: true) }
            }
        }
        if let fnTap { CGEvent.tapEnable(tap: fnTap, enable: true) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let fallbackKey { UnregisterEventHotKey(fallbackKey) }
        if let fallbackHandler { RemoveEventHandler(fallbackHandler) }
        if let fnTap { CFMachPortInvalidate(fnTap) }
        session?.stop()
        session?.task?.cancel()
    }

    @objc private func permissions() {
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            SFSpeechRecognizer.requestAuthorization { speech in
                DispatchQueue.main.async {
                    let accessibility = AXIsProcessTrustedWithOptions(
                        ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    )
                    if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
                    if !allowed || speech != .authorized {
                        self.show("Activa Micrófono y Reconocimiento de voz en Ajustes del Sistema")
                    } else if !accessibility {
                        self.show("Activa Charlado en Privacidad y seguridad → Accesibilidad")
                    } else {
                        self.refreshSetup()
                    }
                }
            }
        }
    }

    @objc private func copyLast() {
        guard !lastText.isEmpty else { return }
        if copyToClipboard(lastText) { show("Último dictado copiado") }
    }

    private func show(_ text: String, icon: String = "🎙") {
        let symbol: String
        switch icon {
        case "🔴": symbol = "waveform.circle.fill"
        case "…": symbol = "ellipsis.circle"
        case "🎙!": symbol = "mic.badge.exclamationmark"
        default: symbol = "mic"
        }
        status.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Charlado")
        status.button?.contentTintColor = icon == "🔴" ? .systemRed : nil
        status.button?.toolTip = text
        status.button?.setAccessibilityLabel(text)
        message.title = text
        setupStatus.stringValue = text
    }

    @objc private func testMicrophone() {
        if let session {
            if session.isTest { endRecording(session) }
        } else {
            startRecording(isTest: true)
        }
    }

    private func press() {
        guard !held else { return }
        held = true
        startRecording(isTest: false)
    }

    private func startRecording(isTest: Bool) {
        guard session == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            show("Falta el permiso de Micrófono", icon: "🎙!")
            return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            show("Falta el permiso de Reconocimiento de voz", icon: "🎙!")
            return
        }
        guard speechLocale != nil else {
            prepareSpeech()
            return
        }

        let recording = Recording(isTest: isTest)
        let input = recording.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            show("No hay una entrada de audio disponible", icon: "🎙!")
            return
        }

        do {
            let file = try AVAudioFile(forWriting: recording.url, settings: format.settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                do { try file.write(from: buffer) }
                catch { NSLog("Charlado: error escribiendo audio: %@", String(describing: error)) }
            }
            do { try recording.engine.start() }
            catch {
                recording.stop()
                throw error
            }
        } catch {
            show("No se pudo abrir el micrófono", icon: "🎙!")
            return
        }

        session = recording
        indicator.show(processing: false, test: isTest, fallback: fallbackDown)
        if isTest {
            testResult.stringValue = ""
            testButton.title = "Terminar prueba"
        }
        show(isTest ? "Grabando. Habla y pulsa Terminar prueba" :
             "Grabando. Suelta el atajo para terminar", icon: "🔴")
    }

    private func release() {
        held = false
        guard let recording = session, !recording.isTest else { return }
        endRecording(recording)
    }

    private func endRecording(_ recording: Recording) {
        guard !recording.stopped, let locale = speechLocale else { return }
        recording.stop()
        indicator.show(processing: true)
        show("Procesando dictado", icon: "…")
        recording.task = Task { @MainActor [weak self, weak recording] in
            guard let self, let recording else { return }
            do {
                recording.latest = try await LocalSpeech.transcribe(recording.url, locale: locale)
                guard self.session === recording else { return }
                self.finish(recording, interrupted: false)
            } catch {
                guard self.session === recording else { return }
                NSLog("Charlado: error de transcripción: %@", String(describing: error))
                self.finish(recording, interrupted: true)
            }
        }
    }

    private func finish(_ recording: Recording, interrupted: Bool) {
        session = nil
        indicator.hide()
        testButton.title = "Probar micrófono"
        recording.stop()
        recording.task?.cancel()
        let text = clean(recording.latest)
        guard !text.isEmpty else {
            show(interrupted ? "El reconocimiento se interrumpió" : "No se detectó texto", icon: "🎙!")
            return
        }
        lastText = text
        if recording.isTest {
            testResult.stringValue = text
            show(interrupted ? "Prueba interrumpida. Se recuperó texto parcial" : "Prueba de voz completada")
            return
        }
        guard copyToClipboard(text) else {
            show("Usa Copiar último dictado para recuperar el texto", icon: "🎙!")
            return
        }
        if !interrupted, recording.destination?.requestPaste() == true {
            diagnostics.notice("Entrega: pegado solicitado")
            show("Pegado solicitado. El texto también está en el portapapeles")
        } else {
            diagnostics.notice("Entrega: portapapeles")
            show("Dictado en el portapapeles. Pega con ⌘V")
        }
    }
}

if CommandLine.arguments.dropFirst() == ["--check"] {
    precondition(clean("  mañana   a las tres. \n") == "Mañana a las tres.")
    precondition(clean("  ") == "")
    precondition(clean("¿Llegó Charlado?") == "¿Llegó Charlado?")
    print("Limpieza de texto verificada")
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--iconset" {
    try CharladoMark.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--transcribe-test" {
    let audio = URL(fileURLWithPath: CommandLine.arguments[2])
    Task {
        do {
            let locale = try await LocalSpeech.prepare()
            print(try await LocalSpeech.transcribe(audio, locale: locale))
            exit(0)
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
} else {
    let application = NSApplication.shared
    let delegate = Dictation()
    application.delegate = delegate
    application.run()
}
