import AppKit
import Foundation

struct TranscriptSegment: Codable {
    let seconds: Double
    let text: String
    var source: String? = nil
}

enum CharladoFiles {
    static let root = URL.applicationSupportDirectory.appending(path: "Charlado", directoryHint: .isDirectory)
    static let meetings = root.appending(path: "Meetings", directoryHint: .isDirectory)
    static let shared = root.appending(path: "Shared Meetings", directoryHint: .isDirectory)
    static let model = root.appending(path: "Models/ggml-base-q5_1.bin")
}

enum PersonalVocabulary {
    private static let words = try! NSRegularExpression(pattern: #"[\p{L}][\p{L}\p{M}\p{N}_'’.-]*"#)

    static var terms: [String] {
        UserDefaults.standard.stringArray(forKey: "vocabulary") ?? []
    }

    static func save(_ items: [String]) {
        var seen = Set<String>()
        let clean = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 50 && seen.insert($0.lowercased()).inserted }
        UserDefaults.standard.set(Array(clean.prefix(30)), forKey: "vocabulary")
    }

    static func suggestions(before: String, after: String, existing: [String]) -> [String] {
        guard before != after, existing.count < 30 else { return [] }
        func tokenize(_ text: String) -> [String] {
            words.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            }
        }
        let old = tokenize(before)
        let new = tokenize(after)
        let oldKeys = old.map { $0.lowercased() }
        let newKeys = new.map { $0.lowercased() }
        let common = min(old.count, new.count)
        var first = 0
        while first < common, oldKeys[first] == newKeys[first] { first += 1 }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > first, newEnd > first, oldKeys[oldEnd - 1] == newKeys[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        guard oldEnd > first, newEnd > first, oldEnd - first <= 800, newEnd - first <= 800 else { return [] }
        let previous = Array(oldKeys[first..<oldEnd])
        let revised = Array(newKeys[first..<newEnd])
        let diff = revised.difference(from: previous)
        let removals = Set(diff.removals.map { change -> Int in
            if case let .remove(offset, _, _) = change { return offset }
            return -1
        })
        let insertions = Set(diff.insertions.map { change -> Int in
            if case let .insert(offset, _, _) = change { return offset }
            return -1
        })
        var seen = Set(existing.map { $0.lowercased() })
        var found: [String] = []
        var i = 0
        var j = 0
        let limit = min(5, 30 - existing.count)
        while (i < previous.count || j < revised.count) && found.count < limit {
            let removedStart = i
            let insertedStart = j
            while removals.contains(i) { i += 1 }
            while insertions.contains(j) { j += 1 }
            if (1...5).contains(i - removedStart), (1...3).contains(j - insertedStart) {
                let term = new[(first + insertedStart)..<(first + j)].joined(separator: " ")
                if term.count <= 50, seen.insert(term.lowercased()).inserted { found.append(term) }
            }
            if i < previous.count, j < revised.count {
                i += 1
                j += 1
            } else {
                break
            }
        }
        return found
    }

    static func offerCorrections(before: String, after: String, in window: NSWindow,
                                 onAdded: @escaping (Int) -> Void) {
        let suggestions = suggestions(before: before, after: after, existing: terms)
        guard !suggestions.isEmpty, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Añadir al vocabulario"
        alert.informativeText = "Charlado puede usar los términos seleccionados como ayuda en futuros dictados mixtos."
        alert.addButton(withTitle: "Añadir seleccionados")
        alert.addButton(withTitle: "Ahora no")
        let choices = suggestions.map { term in
            let button = NSButton(checkboxWithTitle: term, target: nil, action: nil)
            button.state = .on
            return button
        }
        let list = NSStackView(views: choices)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 5
        list.frame = NSRect(origin: .zero, size: list.fittingSize)
        alert.accessoryView = list
        alert.beginSheetModal(for: window) { result in
            guard result == .alertFirstButtonReturn else { return }
            let before = terms
            save(before + choices.filter { $0.state == .on }.map(\.title))
            onAdded(terms.count - before.count)
        }
    }

    static func apply(_ terms: [String], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !terms.isEmpty else { return segments }
        let byName = Dictionary(terms.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let choices = terms.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        guard let pattern = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])(?:\(choices))(?![\\p{L}\\p{N}_])",
            options: [.caseInsensitive]) else { return segments }
        return segments.map { segment in
            let result = NSMutableString(string: segment.text)
            let range = NSRange(segment.text.startIndex..., in: segment.text)
            for match in pattern.matches(in: segment.text, range: range).reversed() {
                if let spelling = byName[result.substring(with: match.range).lowercased()] {
                    result.replaceCharacters(in: match.range, with: spelling)
                }
            }
            return TranscriptSegment(seconds: segment.seconds, text: String(result), source: segment.source)
        }
    }
}

enum MixedSpeech {
    static var executable: URL? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    static var isReady: Bool {
        executable != nil && FileManager.default.isReadableFile(atPath: CharladoFiles.model.path)
    }

    static func transcribe(_ audio: URL, terms: [String]) async throws -> [TranscriptSegment] {
        guard let executable, isReady else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let wave = directory.appending(path: "input.wav")
        let output = directory.appending(path: "transcript")
        try run(URL(fileURLWithPath: "/usr/bin/afconvert"),
                ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, wave.path])
        try Task.checkCancellation()
        var args = ["-m", CharladoFiles.model.path, "-f", wave.path, "-l", "auto",
                    "-oj", "-of", output.path, "-np"]
        if !terms.isEmpty { args += ["--prompt", terms.joined(separator: ", ")] }
        try run(executable, args)
        try Task.checkCancellation()
        let result = try JSONDecoder().decode(Output.self, from: Data(contentsOf: output.appendingPathExtension("json")))
        return result.transcription.compactMap {
            let text = clean($0.text)
            return text.isEmpty ? nil : TranscriptSegment(seconds: $0.offsets.from / 1000, text: text)
        }
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Charlado.\(executable.lastPathComponent)", code: Int(process.terminationStatus))
        }
    }

    private struct Output: Decodable {
        struct Segment: Decodable {
            struct Offsets: Decodable { let from: Double }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Segment]
    }
}

struct MeetingNote: Codable {
    let id: UUID
    let date: Date
    var title: String
    let language: String
    let markers: [Double]
    let segments: [TranscriptSegment]
    var notes: String
    var captureWarning: String? = nil
    var editedTranscript: String? = nil
    var draft: String? = nil

    var transcriptText: String {
        editedTranscript ?? segments.map {
            let speaker = $0.source.map { " **\($0):**" } ?? ""
            return "**\(Self.timestamp($0.seconds))**\(speaker) \($0.text)"
        }.joined(separator: "\n\n")
    }

    var markdown: String {
        let points = markers.map { "- \(Self.timestamp($0))" }.joined(separator: "\n")
        let warning = captureWarning.map { "\n> \($0)\n" } ?? ""
        let draftSection = draft.map { "## Borrador de la reunión\n\n" + $0 + "\n\n" } ?? ""
        return """
        # \(title)

        \(date.formatted(date: .abbreviated, time: .shortened)) · \(language)
        \(warning)
        \(draftSection)## Notas de la reunión

        \(notes)

        ## Momentos marcados

        \(points)

        ## Transcripción

        \(transcriptText)
        """
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? min(max(0, seconds), Double(Int32.max)) : 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func list(in directory: URL) -> [MeetingNote] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return try? JSONDecoder().decode(MeetingNote.self, from: data)
        }.sorted { $0.date > $1.date }
    }

    func save(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: location(in: directory), options: .atomic)
    }

    func location(in directory: URL) -> URL {
        directory.appending(path: id.uuidString + ".json")
    }
}

struct MeetingSearchHit {
    let meetingID: UUID
    let title: String
    let minute: String?
    let preview: String
    let range: NSRange
}

enum MeetingSearch {
    private static let stamps = try! NSRegularExpression(pattern: #"(?m)^\*\*([0-9]+:[0-5][0-9])\*\*[ \t]*"#)

    static func find(_ query: String, in meetings: [MeetingNote]) -> [MeetingSearchHit] {
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return [] }
        return meetings.flatMap { meeting -> [MeetingSearchHit] in
            let text = meeting.transcriptText as NSString
            let whole = NSRange(location: 0, length: text.length)
            let matches = stamps.matches(in: text as String, range: whole)
            let starts = [0] + matches.map { NSMaxRange($0.range) }
            let ends = matches.map { $0.range.location } + [text.length]
            return starts.indices.compactMap { index in
                let block = NSRange(location: starts[index], length: ends[index] - starts[index])
                let hit = text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive], range: block)
                guard hit.location != NSNotFound else { return nil }
                let minute = index == 0 ? nil : text.substring(with: matches[index - 1].range(at: 1))
                let previewStart = max(block.location, hit.location - 28)
                let previewEnd = min(NSMaxRange(block), NSMaxRange(hit) + 48)
                let previewRange = text.rangeOfComposedCharacterSequences(
                    for: NSRange(location: previewStart, length: previewEnd - previewStart))
                let preview = text.substring(with: previewRange)
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return MeetingSearchHit(meetingID: meeting.id, title: meeting.title,
                                        minute: minute, preview: preview, range: hit)
            }
        }
    }
}

final class MeetingLibrary: NSObject {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 640),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private let picker = NSPopUpButton()
    private let search = NSSearchField()
    private let results = NSPopUpButton()
    private let resultCount = NSTextField(labelWithString: "")
    private let resultRow = NSStackView()
    private lazy var jump = NSButton(title: "Ir al fragmento", target: self, action: #selector(jumpToResult))
    private var hits: [MeetingSearchHit] = []
    private let titleField = NSTextField(string: "")
    private let notesField = NSTextField(string: "")
    private let transcript = NSTextView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let accessStatus = NSTextField(labelWithString: "")
    private var selectionActions: [NSButton] = []
    private lazy var share = NSButton(title: "Compartir con MCP", target: self, action: #selector(toggleShare))
    private var entries: [MeetingNote] = []

    override init() {
        super.init()
        window.title = "Reuniones · Charlado"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 630, height: 580)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = CharladoMark.paper
        let heading = NSTextField(labelWithString: "Reuniones")
        heading.font = .systemFont(ofSize: 30, weight: .heavy)
        let access = NSButton(title: "Configurar MCP…", target: self, action: #selector(showConnections))
        let header = NSStackView(views: [heading, NSView(), access])
        header.alignment = .centerY
        accessStatus.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        accessStatus.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        picker.target = self
        picker.action = #selector(selectMeeting)
        picker.setAccessibilityLabel("Reunión seleccionada")
        search.placeholderString = "Buscar una frase en todas las reuniones"
        search.setAccessibilityLabel("Buscar en todas las reuniones")
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(updateSearch)
        results.setAccessibilityLabel("Resultados de búsqueda")
        results.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resultCount.font = .systemFont(ofSize: 12)
        resultCount.textColor = .secondaryLabelColor
        resultRow.alignment = .centerY
        resultRow.spacing = 8
        for view in [results, jump, resultCount] { resultRow.addArrangedSubview(view) }
        resultRow.isHidden = true
        titleField.placeholderString = "Título de la reunión"
        titleField.setAccessibilityLabel("Título de la reunión")
        notesField.placeholderString = "Decisiones, tareas y preguntas abiertas"
        notesField.setAccessibilityLabel("Notas de la reunión")
        transcript.isEditable = false
        transcript.isRichText = false
        transcript.setAccessibilityLabel("Transcripción editable")
        transcript.font = .systemFont(ofSize: 14)
        transcript.textContainerInset = NSSize(width: 10, height: 10)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = transcript
        transcript.isVerticallyResizable = true
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        selectionActions = [
            NSButton(title: "Decisiones y tareas…", target: self, action: #selector(showDraft)),
            NSButton(title: "Guardar cambios", target: self, action: #selector(save)),
            NSButton(title: "Copiar para IA", target: self, action: #selector(copyMeeting)),
            NSButton(title: "Exportar Markdown", target: self, action: #selector(exportMarkdown))
        ]
        let actions = NSStackView(views: selectionActions)
        actions.spacing = 8
        let sharing = NSStackView(views: [accessStatus, NSView(), share])
        sharing.alignment = .centerY
        let rows = NSStackView(views: [header, search, resultRow, picker, titleField, notesField, sharing, scroll, actions, message])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            rows.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: rows.widthAnchor),
            search.widthAnchor.constraint(equalTo: rows.widthAnchor),
            resultRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            sharing.widthAnchor.constraint(equalTo: rows.widthAnchor),
            picker.widthAnchor.constraint(equalTo: rows.widthAnchor),
            titleField.widthAnchor.constraint(equalTo: rows.widthAnchor),
            notesField.widthAnchor.constraint(equalTo: rows.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: rows.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            message.widthAnchor.constraint(equalTo: rows.widthAnchor)
        ])
        window.center()
    }

    func open(selecting id: UUID? = nil) {
        if id == nil, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        entries = MeetingNote.list(in: CharladoFiles.meetings)
        picker.removeAllItems()
        picker.addItems(withTitles: entries.enumerated().map { "\($0.offset + 1). \($0.element.title)" })
        if let id, let index = entries.firstIndex(where: { $0.id == id }) { picker.selectItem(at: index) }
        selectMeeting()
        updateSearch()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func updateSearch() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        resultRow.isHidden = query.isEmpty
        let matches = MeetingSearch.find(query, in: entries)
        hits = Array(matches.prefix(100))
        results.removeAllItems()
        results.addItems(withTitles: hits.enumerated().map { index, hit in
            "\(index + 1). \(hit.minute ?? "Sin minuto") · \(hit.title) · \(hit.preview)"
        })
        results.isHidden = hits.isEmpty
        jump.isHidden = hits.isEmpty
        switch matches.count {
        case 0: resultCount.stringValue = "Sin coincidencias"
        case 1: resultCount.stringValue = "1 coincidencia"
        case 2...100: resultCount.stringValue = "\(matches.count) coincidencias"
        default: resultCount.stringValue = "100 de \(matches.count)"
        }
    }

    @objc private func jumpToResult() {
        guard hits.indices.contains(results.indexOfSelectedItem) else { return }
        let hit = hits[results.indexOfSelectedItem]
        guard let index = entries.firstIndex(where: { $0.id == hit.meetingID }) else { return }
        if let selected, let edited,
           edited.title != selected.title || edited.notes != selected.notes ||
               edited.transcriptText != selected.transcriptText {
            message.stringValue = "Guarda los cambios antes de abrir un resultado de búsqueda."
            return
        }
        picker.selectItem(at: index)
        selectMeeting()
        window.makeFirstResponder(transcript)
        transcript.setSelectedRange(hit.range)
        transcript.scrollRangeToVisible(hit.range)
        message.stringValue = hit.minute.map { "Fragmento en \($0)" } ?? "Fragmento sin marca de tiempo"
    }

    private var selected: MeetingNote? {
        guard entries.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return entries[picker.indexOfSelectedItem]
    }

    private var edited: MeetingNote? {
        guard var note = selected else { return nil }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { note.title = title }
        note.notes = notesField.stringValue
        if transcript.string != note.transcriptText { note.editedTranscript = transcript.string }
        return note
    }

    private func isShared(_ note: MeetingNote) -> Bool {
        FileManager.default.fileExists(atPath: note.location(in: CharladoFiles.shared).path)
    }

    @objc private func selectMeeting() {
        titleField.stringValue = selected?.title ?? ""
        notesField.stringValue = selected?.notes ?? ""
        transcript.isEditable = selected != nil
        transcript.string = selected?.transcriptText ?? "Aún no hay reuniones. Inicia una desde la barra de menú."
        let shared = selected.map(isShared) == true
        share.title = shared ? "Retirar acceso MCP" : "Compartir con MCP"
        accessStatus.stringValue = selected == nil ? "SIN REUNIONES" :
            (shared ? "ACCESO MCP · COMPARTIDA" : "ACCESO MCP · PRIVADA")
        for button in selectionActions + [share] { button.isEnabled = selected != nil }
        titleField.isEditable = selected != nil
        notesField.isEditable = selected != nil
        let marks = selected?.markers.map(MeetingNote.timestamp).joined(separator: " · ") ?? ""
        message.stringValue = [selected?.captureWarning, marks.isEmpty ? nil : "Marcas · " + marks]
            .compactMap { $0 }.joined(separator: "\n")
    }

    @objc private func save() {
        guard let note = edited, let original = selected else { return }
        do {
            try note.save(in: CharladoFiles.meetings)
            if isShared(note) { try note.save(in: CharladoFiles.shared) }
            open(selecting: note.id)
            message.stringValue = "Cambios guardados"
            PersonalVocabulary.offerCorrections(before: original.transcriptText, after: note.transcriptText,
                                                in: window) { count in
                if count > 0 { self.message.stringValue = "Vocabulario actualizado" }
            }
        } catch { message.stringValue = "No se pudieron guardar los cambios" }
    }

    @objc func showDraft() {
        guard let note = selected, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Decisiones y tareas"
        alert.informativeText = "Revisa el borrador antes de usarlo. Los minutos apuntan al inicio del fragmento de origen."
        alert.addButton(withTitle: "Guardar borrador")
        alert.addButton(withTitle: "Cancelar")

        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 245))
        editor.isRichText = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 9, height: 9)
        editor.string = note.draft ?? MeetingDraft.empty
        editor.setAccessibilityLabel("Borrador editable de decisiones y tareas")
        let scroll = NSScrollView(frame: editor.frame)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = editor
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn,
                  let index = self.entries.firstIndex(where: { $0.id == note.id }) else { return }
            do {
                var updated = self.entries[index]
                updated.draft = editor.string
                try updated.save(in: CharladoFiles.meetings)
                self.entries[index] = updated
                if self.isShared(updated) { try updated.save(in: CharladoFiles.shared) }
                self.message.stringValue = "Borrador guardado"
            } catch {
                self.message.stringValue = "No se pudo guardar el borrador"
            }
        }
    }

    @objc private func copyMeeting() {
        guard let note = edited else { return }
        let request = """
        Resume esta reunión en decisiones, tareas y preguntas abiertas. Cita la marca de tiempo de cada punto.
        Si una tarea carece de responsable o fecha explícitos, indícalo. Usa la transcripción como evidencia.

        ---
        """
        guard copyToClipboard(request + "\n\n" + note.markdown) else { return }
        message.stringValue = "Reunión copiada. Puedes pegarla en ChatGPT o Claude"
    }

    @objc private func exportMarkdown() {
        guard let note = edited else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Reunión.md"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try note.markdown.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.message.stringValue = "No se pudo exportar la reunión" }
        }
    }

    @objc func showConnections() {
        guard window.attachedSheet == nil else { return }
        let count = MeetingNote.list(in: CharladoFiles.shared).count
        let alert = NSAlert()
        alert.messageText = "Conexiones MCP"
        alert.informativeText = """
        \(count) reuniones disponibles para los clientes que configures. Comparte cada reunión desde la biblioteca.

        Claude Code se configura con un comando local. ChatGPT usa un túnel seguro. Verifica la conexión desde tu cliente antes de consultar una reunión.
        """
        alert.addButton(withTitle: "Listo")
        alert.addButton(withTitle: "Copiar comando Claude Code")
        alert.addButton(withTitle: "Copiar comando para túnel")
        alert.beginSheetModal(for: window) { response in
            let executable = Bundle.main.executableURL?.path ?? ""
            let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            if response == .alertSecondButtonReturn {
                copyToClipboard("claude mcp add --scope user --transport stdio charlado -- \(quoted) --mcp")
                self.message.stringValue = "Comando de Claude Code copiado"
            } else if response == .alertThirdButtonReturn {
                copyToClipboard("\(quoted) --mcp")
                self.message.stringValue = "Comando local copiado. Úsalo como mcp-command en el túnel"
            }
        }
    }

    @objc private func toggleShare() {
        guard let note = selected else { return }
        do {
            if isShared(note) {
                try FileManager.default.removeItem(at: note.location(in: CharladoFiles.shared))
            } else {
                let alert = NSAlert()
                alert.messageText = "Compartir esta reunión con MCP"
                alert.informativeText = "Los clientes MCP que conectes podrán leer la transcripción y las notas de esta reunión."
                alert.addButton(withTitle: "Compartir")
                alert.addButton(withTitle: "Cancelar")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                guard let updated = edited else { return }
                try updated.save(in: CharladoFiles.meetings)
                try updated.save(in: CharladoFiles.shared)
                open(selecting: updated.id)
            }
            share.title = isShared(note) ? "Retirar acceso MCP" : "Compartir con MCP"
            accessStatus.stringValue = isShared(note) ? "ACCESO MCP · COMPARTIDA" : "ACCESO MCP · PRIVADA"
            message.stringValue = isShared(note) ? "Visible para el MCP local" : "Retirada del MCP local"
        } catch { message.stringValue = "No se pudo cambiar el acceso" }
    }
}
