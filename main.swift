import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import OSLog
import Speech
import ScreenCaptureKit

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
    private enum Focus {
        case editor(element: AXUIElement, selection: CFTypeRef?)
        case terminal(window: AXUIElement, element: AXUIElement?)
    }

    private let pid: pid_t
    private let bundleID: String
    private let focus: Focus

    private static func element(_ value: CFTypeRef?, belongingTo pid: pid_t) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var owner: pid_t = 0
        return AXUIElementGetPid(element, &owner) == .success && owner == pid ? element : nil
    }

    static func current() -> Destination? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? "desconocida"
        let appElement = AXUIElementCreateApplication(pid)
        let focused = element(attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
                              belongingTo: pid)
            ?? element(attribute(appElement, kAXFocusedUIElementAttribute), belongingTo: pid)

        if let focused, attribute(focused, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
            return nil
        }

        // Shell output can change AXSelectedTextRange even when the terminal pane stays focused.
        if bundleID == "com.apple.Terminal" || bundleID == "com.googlecode.iterm2" {
            guard !IsSecureEventInputEnabled(),
                  let window = element(attribute(appElement, kAXFocusedWindowAttribute), belongingTo: pid)
            else { return nil }
            return Destination(pid: pid, bundleID: bundleID, focus: .terminal(window: window, element: focused))
        }

        guard let focused, let role = attribute(focused, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
        else {
            diagnostics.notice("Sin campo compatible en \(bundleID, privacy: .public)")
            return nil
        }
        return Destination(pid: pid, bundleID: bundleID,
                           focus: .editor(element: focused, selection: attribute(focused, kAXSelectedTextRangeAttribute)))
    }

    func requestPaste() -> Bool {
        guard stillFocused() else {
            diagnostics.notice("Cambió el destino de pegado en \(bundleID, privacy: .public)")
            return false
        }
        guard CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            diagnostics.notice("macOS no permitió solicitar el pegado en \(bundleID, privacy: .public)")
            return false
        }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        diagnostics.notice("Pegado solicitado en \(bundleID, privacy: .public)")
        return true
    }

    private func stillFocused() -> Bool {
        guard let current = Self.current(), pid == current.pid else { return false }
        switch (focus, current.focus) {
        case let (.editor(element, selection), .editor(other, otherSelection)):
            guard CFEqual(element, other) else { return false }
            guard let selection else { return true }
            return otherSelection.map { CFEqual(selection, $0) } ?? false
        case let (.terminal(window, element), .terminal(otherWindow, otherElement)):
            guard CFEqual(window, otherWindow) else { return false }
            if let element, let otherElement { return CFEqual(element, otherElement) }
            return element == nil && otherElement == nil
        default:
            return false
        }
    }
}

@discardableResult
func copyToClipboard(_ text: String) -> Bool {
    let board = NSPasteboard.general
    board.clearContents()
    return board.setString(text, forType: .string)
}

enum DictationLanguage: String, CaseIterable {
    case spanish = "es"
    case english = "en"
    case mixed = "mixed"

    var title: String {
        switch self {
        case .spanish: return "Español"
        case .english: return "English"
        case .mixed: return "Mixto ES + EN"
        }
    }
    var localeIdentifiers: [String] {
        switch self {
        case .spanish: return ["es-CO", "es-MX", "es-ES", "es-US"]
        case .english: return ["en-US", "en-GB"]
        case .mixed: return []
        }
    }
}

private func audioWriter(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false
    return try AVAudioFile(forWriting: url, settings: settings,
                           commonFormat: format.commonFormat, interleaved: format.isInterleaved)
}

final class AudioCapture {
    enum Outcome {
        case recorded, empty, writeFailed
    }

    private let lock = NSLock()
    private let file: AVAudioFile
    private var frames: AVAudioFramePosition = 0
    private var writeFailed = false
    private var closed = false

    init(url: URL, format: AVAudioFormat) throws {
        file = try audioWriter(at: url, format: format)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !closed, !writeFailed else { return }
            do {
                try file.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
            } catch {
                writeFailed = true
                diagnostics.error("Falló la escritura de audio: \((error as NSError).code)")
            }
        }
    }

    func finish() -> Outcome {
        lock.withLock {
            if !closed {
                closed = true
                file.close()
            }
            if writeFailed { return .writeFailed }
            return frames > 0 ? .recorded : .empty
        }
    }
}

enum LocalSpeech {
    static func prepare(_ language: DictationLanguage) async throws -> Locale {
        for identifier in language.localeIdentifiers {
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

    static func transcribe(_ url: URL, locale: Locale, terms: [String] = []) async throws -> [TranscriptSegment] {
        let paddedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: paddedURL) }
        try appendTrailingSilence(from: url, to: paddedURL)
        let audio = try AVAudioFile(forReading: paddedURL)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try await analyzer.setContext(context)
        }
        async let output = collect(transcriber)
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
        let output = try audioWriter(at: destination, format: format)
        defer { output.close() }
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

    private static func collect(_ transcriber: SpeechTranscriber) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(TranscriptSegment(seconds: result.range.start.seconds, text: text)) }
        }
        return segments
    }
}

final class Dictation: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var speechLocale: Locale?
    private lazy var library = MeetingLibrary()
    private var vocabulary: [String] {
        UserDefaults.standard.stringArray(forKey: "vocabulary") ?? []
    }
    private let meetingItem = NSMenuItem(title: "Iniciar reunión", action: #selector(toggleMeeting), keyEquivalent: "")
    private let callItem = NSMenuItem(title: "Grabar llamada…", action: #selector(startCallMeeting), keyEquivalent: "")
    private var startingCall = false
    private let pauseItem = NSMenuItem(title: "Pausar reunión", action: #selector(toggleMeetingPause), keyEquivalent: "")
    private let markerItem = NSMenuItem(title: "Marcar momento", action: #selector(markMeeting), keyEquivalent: "")
    private var meetingTimer: Timer?
    private lazy var meetingButton = NSButton(title: "Iniciar reunión", target: self, action: #selector(toggleMeeting))
    private var language = UserDefaults.standard.string(forKey: "dictationLanguage")
        .flatMap(DictationLanguage.init(rawValue:)) ?? .spanish
    private lazy var languagePicker: NSPopUpButton = {
        let picker = NSPopUpButton()
        picker.addItems(withTitles: DictationLanguage.allCases.map(\.title))
        picker.selectItem(withTitle: language.title)
        picker.target = self
        picker.action = #selector(changeLanguage)
        picker.setAccessibilityLabel("Idioma del dictado")
        return picker
    }()
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
    private lazy var indicator = DictationIndicator(target: self, stopAction: #selector(stopMeetingFromIndicator))
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
        let isMeeting: Bool
        let startedAt = Date()
        let callAudio: CallAudio?
        var markers: [Double] = []
        var elapsed: Double = 0
        var resumedAt = ProcessInfo.processInfo.systemUptime
        var paused = false
        var task: Task<Void, Never>?
        var capture: AudioCapture?
        var captureOutcome: AudioCapture.Outcome = .empty
        var latest = ""
        var stopped = false

        init(isTest: Bool, isMeeting: Bool, callAudio: CallAudio?) {
            self.callAudio = callAudio
            self.isTest = isTest
            self.isMeeting = isMeeting
            destination = !isTest && !isMeeting && AXIsProcessTrusted() ? Destination.current() : nil
        }

        var activeDuration: Double {
            elapsed + (paused ? 0 : ProcessInfo.processInfo.systemUptime - resumedAt)
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            captureOutcome = capture?.finish() ?? .empty
            capture = nil
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.addItem(message)
        menu.addItem(NSMenuItem(title: "Abrir Charlado", action: #selector(openSetup), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Configurar permisos", action: #selector(permissions), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Vocabulario personal…", action: #selector(editVocabulary), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(meetingItem)
        menu.addItem(callItem)
        menu.addItem(pauseItem)
        menu.addItem(markerItem)
        menu.addItem(NSMenuItem(title: "Biblioteca de reuniones", action: #selector(openLibrary), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Copiar último dictado", action: #selector(copyLast), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        menu.items.last?.target = NSApp
        menu.delegate = self
        menu.autoenablesItems = false
        updateMeetingMenu()
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
            title.font = .systemFont(ofSize: 38, weight: .heavy)
            title.textColor = CharladoMark.ink
            let subtitle = NSTextField(labelWithString: "DICTADO LOCAL  /  macOS")
            subtitle.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            subtitle.textColor = .secondaryLabelColor
            let brand = NSStackView(views: [title, subtitle])
            brand.orientation = .vertical
            brand.alignment = .leading
            brand.spacing = 2
            let mark = NSImageView(image: CharladoMark.image(size: 64))
            let header = NSStackView(views: [mark, brand])
            header.spacing = 12
            let instructions = NSTextField(wrappingLabelWithString:
                "Mantén Fn mientras hablas. Suelta para pegar el texto donde está el cursor.")
            instructions.font = .systemFont(ofSize: 17, weight: .medium)
            let shortcut = NSTextField(labelWithString: "ATAJO ALTERNATIVO   ⌃ ⌥ D")
            shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            shortcut.textColor = .secondaryLabelColor
            setupStatus.font = .systemFont(ofSize: 13, weight: .semibold)
            fnStatus.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            fnStatus.textColor = .secondaryLabelColor
            let button = NSButton(title: "Configurar permisos", target: self, action: #selector(permissions))
            let background = NSButton(title: "Seguir en segundo plano", target: self,
                                      action: #selector(hideSetup))
            background.bezelStyle = .rounded
            background.controlSize = .large
            background.bezelColor = CharladoMark.accent
            background.setAccessibilityHelp("Oculta la ventana y mantiene activo el atajo de dictado.")
            let actions = NSStackView(views: [background, button])
            actions.alignment = .centerY
            actions.spacing = 12
            let divider = NSBox()
            divider.boxType = .custom
            divider.borderWidth = 0
            divider.fillColor = CharladoMark.ink
            let languageLabel = NSTextField(labelWithString: "Idioma del dictado")
            languageLabel.font = .systemFont(ofSize: 13, weight: .medium)
            let languageRow = NSStackView(views: [languageLabel, languagePicker])
            languageRow.alignment = .centerY
            languageRow.spacing = 12
            let meetingActions = NSStackView(views: [
                meetingButton,
                NSButton(title: "Biblioteca", target: self, action: #selector(openLibrary)),
                NSButton(title: "Vocabulario", target: self, action: #selector(editVocabulary))
            ])
            meetingActions.spacing = 12
            let stack = NSStackView(views: [header, instructions, shortcut, divider, languageRow,
                                            setupStatus, fnStatus, actions, meetingActions, testButton, testResult])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 16
            stack.translatesAutoresizingMaskIntoConstraints = false

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Charlado"
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = CharladoMark.paper
            window.delegate = self
            window.isReleasedWhenClosed = false
            if let content = window.contentView {
                content.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                    stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                    stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                    mark.widthAnchor.constraint(equalToConstant: 64),
                    mark.heightAnchor.constraint(equalToConstant: 64),
                    divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
                    divider.heightAnchor.constraint(equalToConstant: 1),
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
        if fnTap == nil, session == nil { refreshSetup() }
        updateMeetingMenu()
    }

    private func updateMeetingMenu() {
        let meeting = session?.isMeeting == true
        let active = meeting && session?.stopped == false
        meetingItem.title = active ? "Terminar reunión" : "Iniciar reunión"
        meetingItem.isEnabled = !startingCall && (session == nil || active)
        meetingButton.title = meetingItem.title
        meetingButton.isEnabled = meetingItem.isEnabled
        callItem.isEnabled = !startingCall && session == nil
        pauseItem.title = session?.paused == true ? "Reanudar reunión" : "Pausar reunión"
        pauseItem.isEnabled = active
        markerItem.isEnabled = active && session?.paused == false
    }

    @objc private func toggleMeeting() {
        if let session {
            if session.isMeeting { endRecording(session) }
            return
        }
        startRecording(isTest: false, isMeeting: true)
    }

    @objc private func startCallMeeting() {
        guard session == nil, !startingCall else { return }
        guard language == .mixed ? MixedSpeech.isReady : speechLocale != nil else {
            prepareSpeech()
            return
        }
        startingCall = true
        languagePicker.isEnabled = false
        updateMeetingMenu()
        Task { @MainActor in
            defer {
                startingCall = false
                languagePicker.isEnabled = session == nil
                updateMeetingMenu()
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                        ?? content.displays.first else { throw CocoaError(.featureUnsupported) }
                let applications = content.applications.filter {
                    !$0.applicationName.isEmpty && $0.processID != ProcessInfo.processInfo.processIdentifier
                }.sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
                guard !applications.isEmpty else {
                    show("Abre primero la aplicación de la llamada", icon: "🎙!")
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Grabar llamada"
                alert.informativeText = "Selecciona la aplicación de la llamada. Charlado graba su audio y tu micrófono. Avisa a los participantes antes de empezar."
                alert.addButton(withTitle: "Empezar")
                alert.addButton(withTitle: "Cancelar")
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
                picker.addItems(withTitles: applications.enumerated().map { "\($0.offset + 1). \($0.element.applicationName)" })
                alert.accessoryView = picker
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn,
                      applications.indices.contains(picker.indexOfSelectedItem) else { return }
                let source = CallAudio()
                try await source.start(display: display, application: applications[picker.indexOfSelectedItem])
                startingCall = false
                startRecording(isTest: false, isMeeting: true, callAudio: source)
                if session?.callAudio !== source { _ = await source.stop() }
            } catch {
                let failure = error as NSError
                diagnostics.error("No se pudo iniciar captura de llamada: \(failure.domain, privacy: .public) (\(failure.code))")
                show("No se pudo capturar la llamada. Revisa Grabación de pantalla y audio del sistema en Ajustes", icon: "🎙!")
            }
        }
    }

    @objc private func stopMeetingFromIndicator() {
        guard let session, session.isMeeting else { return }
        endRecording(session)
    }

    @objc private func toggleMeetingPause() {
        guard let session, session.isMeeting, !session.stopped else { return }
        if session.paused {
            do {
                try session.engine.start()
                session.resumedAt = ProcessInfo.processInfo.systemUptime
                session.paused = false
                session.callAudio?.enable(at: session.elapsed)
            } catch {
                show("No se pudo reanudar el micrófono", icon: "🎙!")
            }
        } else {
            session.elapsed = session.activeDuration
            session.paused = true
            session.engine.pause()
            session.callAudio?.pause()
        }
        updateMeetingDisplay()
        updateMeetingMenu()
    }

    @objc private func markMeeting() {
        guard let session, session.isMeeting, !session.stopped, !session.paused else { return }
        session.markers.append(session.activeDuration)
        updateMeetingDisplay()
    }

    private func updateMeetingDisplay() {
        guard let session, session.isMeeting, !session.stopped else { return }
        let duration = MeetingNote.timestamp(session.activeDuration)
        let title = session.paused ? "Reunión en pausa" : "Grabando reunión"
        let detail = "\(duration) · \(session.markers.count) marcas"
        indicator.showMeeting(title: title, detail: detail)
        show("\(title) · \(detail)", icon: session.paused ? "…" : "🔴")
    }

    @objc private func openLibrary() { library.open() }

    @objc private func editVocabulary() {
        let alert = NSAlert()
        alert.messageText = "Vocabulario personal"
        alert.informativeText = "Escribe nombres o frases cortas separados por comas. Se guardan en este Mac."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 24))
        field.placeholderString = "deploy, staging, pull request"
        field.stringValue = vocabulary.joined(separator: ", ")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var seen = Set<String>()
        let terms = field.stringValue.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && $0.count <= 50 && seen.insert($0.lowercased()).inserted }
        UserDefaults.standard.set(Array(terms.prefix(30)), forKey: "vocabulary")
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

    @objc private func changeLanguage() {
        guard session == nil, !preparingSpeech else { return }
        let selected = DictationLanguage.allCases[languagePicker.indexOfSelectedItem]
        guard selected != language else { return }
        language = selected
        UserDefaults.standard.set(selected.rawValue, forKey: "dictationLanguage")
        speechLocale = nil
        preparationFailed = false
        testResult.stringValue = "El texto de prueba aparecerá aquí."
        prepareSpeech()
    }

    private func prepareSpeech() {
        guard language != .mixed, speechLocale == nil, !preparingSpeech else {
            refreshSetup()
            return
        }
        preparingSpeech = true
        languagePicker.isEnabled = false
        preparationFailed = false
        refreshSetup()
        Task { @MainActor in
            defer {
                preparingSpeech = false
                languagePicker.isEnabled = true
                refreshSetup()
            }
            do { speechLocale = try await LocalSpeech.prepare(language) }
            catch {
                preparationFailed = true
                NSLog("Charlado: error preparando el modelo de idioma: %@", String(describing: error))
            }
        }
    }

    private func refreshSetup() {
        if preparingSpeech {
            show("Preparando el modelo local · \(language.title)…", icon: "…")
            return
        }
        if language == .mixed, !MixedSpeech.isReady {
            show("El modo mixto requiere whisper-cli y el modelo local. Consulta el README", icon: "🎙!")
            return
        }
        if preparationFailed, language != .mixed {
            show("No se pudo preparar \(language.title). Pulsa Probar micrófono para reintentar", icon: "🎙!")
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
            show("Listo en \(language.title). Mantén Fn para dictar")
        } else {
            show("Abre Configurar permisos para completar la configuración", icon: "🎙!")
        }
    }

    private func recoverFnMonitor() {
        if fnDown {
            fnDown = false
            if !fallbackDown {
                held = false
                if let session, !session.stopped, !session.isTest, !session.isMeeting { finish(session, interrupted: true) }
            }
        }
        if let fnTap { CGEvent.tapEnable(tap: fnTap, enable: true) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session, session.isMeeting else { return .terminateNow }
        if session.stopped {
            show("Espera a que se guarde la reunión antes de salir", icon: "…")
            return .terminateCancel
        }
        endRecording(session)
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let fallbackKey { UnregisterEventHotKey(fallbackKey) }
        if let fallbackHandler { RemoveEventHandler(fallbackHandler) }
        if let fnTap { CFMachPortInvalidate(fnTap) }
        meetingTimer?.invalidate()
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

    private func startRecording(isTest: Bool, isMeeting: Bool = false, callAudio: CallAudio? = nil) {
        guard session == nil, !startingCall else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            show("Falta el permiso de Micrófono", icon: "🎙!")
            return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            show("Falta el permiso de Reconocimiento de voz", icon: "🎙!")
            return
        }
        guard language == .mixed ? MixedSpeech.isReady : speechLocale != nil else {
            prepareSpeech()
            return
        }

        let recording = Recording(isTest: isTest, isMeeting: isMeeting, callAudio: callAudio)
        let input = recording.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            show("No hay una entrada de audio disponible", icon: "🎙!")
            return
        }

        do {
            let capture = try AudioCapture(url: recording.url, format: format)
            recording.capture = capture
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                capture.append(buffer)
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
        languagePicker.isEnabled = false
        updateMeetingMenu()
        if isMeeting {
            recording.resumedAt = ProcessInfo.processInfo.systemUptime
            recording.callAudio?.enable(at: 0)
            updateMeetingDisplay()
            meetingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateMeetingDisplay()
            }
            return
        }
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
        guard let recording = session, !recording.isTest, !recording.isMeeting else { return }
        endRecording(recording)
    }

    private func endRecording(_ recording: Recording) {
        guard !recording.stopped else { return }
        let selectedLanguage = language
        let locale = speechLocale
        let terms = vocabulary
        meetingTimer?.invalidate()
        meetingTimer = nil
        recording.callAudio?.pause()
        recording.stop()
        updateMeetingMenu()
        if recording.callAudio == nil {
            switch recording.captureOutcome {
            case .empty:
                finish(recording, interrupted: false, failure: "El micrófono no entregó audio")
                return
            case .writeFailed:
                finish(recording, interrupted: true, failure: "Falló la grabación. Vuelve a intentar con Probar micrófono")
                return
            case .recorded:
                break
            }
        }
        indicator.show(processing: true)
        show("Procesando dictado", icon: "…")
        recording.task = Task { @MainActor [weak self, weak recording] in
            guard let self, let recording else { return }
            do {
                func transcribe(_ url: URL) async throws -> [TranscriptSegment] {
                    if selectedLanguage == .mixed { return try await MixedSpeech.transcribe(url, terms: terms) }
                    guard let locale else { throw CocoaError(.fileNoSuchFile) }
                    return try await LocalSpeech.transcribe(url, locale: locale, terms: terms)
                }
                let callOffset = await recording.callAudio?.stop()
                var segments: [TranscriptSegment] = []
                var warnings: [String] = []
                if recording.captureOutcome == .recorded {
                    if recording.callAudio == nil {
                        segments = try await transcribe(recording.url)
                    } else {
                        do {
                            segments = try await transcribe(recording.url).map {
                                TranscriptSegment(seconds: $0.seconds, text: $0.text, source: "Micrófono")
                            }
                        } catch { warnings.append("No se pudo transcribir el micrófono.") }
                    }
                } else {
                    warnings.append("No se pudo guardar el audio del micrófono.")
                }
                if let call = recording.callAudio {
                    if let offset = callOffset {
                        do {
                            let remote = try await transcribe(call.url).map {
                                TranscriptSegment(seconds: $0.seconds + offset, text: $0.text, source: "Llamada")
                            }
                            if remote.isEmpty { warnings.append("El audio de la llamada no produjo texto.") }
                            segments += remote
                        } catch { warnings.append("No se pudo transcribir el audio de la llamada.") }
                    } else { warnings.append("No se capturó audio de la aplicación seleccionada.") }
                    if call.incomplete { warnings.append("La captura de la llamada se interrumpió.") }
                    segments.sort { $0.seconds < $1.seconds }
                }
                guard self.session === recording else { return }
                segments = PersonalVocabulary.apply(terms, to: segments)
                if recording.isMeeting, !segments.isEmpty {
                    let note = MeetingNote(id: UUID(), date: recording.startedAt,
                                           title: "Reunión " + recording.startedAt.formatted(date: .abbreviated, time: .shortened),
                                           language: selectedLanguage.title, markers: recording.markers,
                                           segments: segments, notes: "",
                                           captureWarning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
                    try note.save(in: CharladoFiles.meetings)
                    self.resetRecording(recording)
                    self.show("Reunión guardada")
                    self.library.open(selecting: note.id)
                } else {
                    recording.latest = segments.map(\.text).joined(separator: " ")
                    self.finish(recording, interrupted: false,
                                failure: warnings.isEmpty ? nil : warnings.joined(separator: " "))
                }
            } catch {
                guard self.session === recording else { return }
                let failure = error as NSError
                diagnostics.error("Falló el reconocimiento en \(selectedLanguage.rawValue, privacy: .public): \(failure.domain, privacy: .public) (\(failure.code))")
                self.finish(recording, interrupted: true)
            }
        }
    }

    private func resetRecording(_ recording: Recording) {
        session = nil
        meetingTimer?.invalidate()
        meetingTimer = nil
        updateMeetingMenu()
        languagePicker.isEnabled = true
        indicator.hide()
        testButton.title = "Probar micrófono"
        recording.stop()
        recording.task?.cancel()
    }

    private func finish(_ recording: Recording, interrupted: Bool, failure: String? = nil) {
        resetRecording(recording)
        let text = clean(recording.latest)
        guard !text.isEmpty else {
            let message = failure ?? (interrupted ? "Falló la transcripción local" :
                "Se grabó audio, pero no se reconocieron palabras en \(language.title)")
            diagnostics.notice("\(message, privacy: .public)")
            if recording.isTest { testResult.stringValue = message }
            show(message, icon: "🎙!")
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
    let sample = TranscriptSegment(seconds: 0, text: "Usa github y pull request en githubdesk.")
    precondition(PersonalVocabulary.apply(["GitHub", "pull request"], to: [sample]).first?.text ==
                 "Usa GitHub y pull request en githubdesk.")
    try MeetingMCP.check()
    print("Limpieza de texto y acceso de reuniones verificados")
} else if CommandLine.arguments.dropFirst() == ["--mcp"] {
    MeetingMCP.run()
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--iconset" {
    try CharladoMark.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
} else if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--transcribe-test",
          let language = DictationLanguage(rawValue: CommandLine.arguments[2]) {
    let audio = URL(fileURLWithPath: CommandLine.arguments[3])
    Task {
        do {
            let segments: [TranscriptSegment]
            if language == .mixed {
                segments = try await MixedSpeech.transcribe(audio, terms: [])
            } else {
                let locale = try await LocalSpeech.prepare(language)
                segments = try await LocalSpeech.transcribe(audio, locale: locale)
            }
            print(clean(segments.map(\.text).joined(separator: " ")))
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
