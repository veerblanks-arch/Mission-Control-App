import AppKit
import Combine
import SwiftUI

struct DroppyNote: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var modifiedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        title: String = "Untitled Note",
        body: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.deletedAt = deletedAt
    }

    var searchableContent: String {
        "\(title)\n\(body)"
    }

    var exportFileName: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled Note" : trimmed
        let safe = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe).md"
    }

    var markdown: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return body
        }
        return "# \(trimmedTitle)\n\n\(body)"
    }
}

struct NotesArchive: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var notes: [DroppyNote] = []
}

enum NotesStoreLoadResult {
    case missing
    case loaded(NotesArchive)
    case failed
}

final class NotesStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let writer: (Data, URL) -> Bool
    private(set) var acceptsWrites = true

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        writer: ((Data, URL) -> Bool)? = nil
    ) {
        self.fileManager = fileManager
        self.writer = writer ?? { data, url in
            do {
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.fileURL = baseURL
                .appendingPathComponent("Droppy", isDirectory: true)
                .appendingPathComponent("Notes", isDirectory: true)
                .appendingPathComponent("Notes.json")
        }
        try? fileManager.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func load() -> NotesStoreLoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let archive = try Self.decoder.decode(NotesArchive.self, from: data)
            guard archive.schemaVersion == NotesArchive.currentSchemaVersion
            else {
                acceptsWrites = false
                return .failed
            }
            return .loaded(archive)
        } catch {
            acceptsWrites = false
            return .failed
        }
    }

    @discardableResult
    func save(_ archive: NotesArchive) -> Bool {
        guard acceptsWrites else {
            return false
        }
        guard let data = try? Self.encoder.encode(archive) else {
            return false
        }
        return writer(data, fileURL)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor
final class NotesFeature: ObservableObject {
    static let shared = NotesFeature()
    static let trashLifetime: TimeInterval = 30 * 24 * 60 * 60

    @Published private(set) var notes: [DroppyNote]
    @Published var selectedNoteID: UUID?
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            selectFirstDisplayedNote()
        }
    }
    @Published var isShowingTrash = false {
        didSet {
            guard isShowingTrash != oldValue else { return }
            selectFirstDisplayedNote()
        }
    }
    @Published private(set) var storageErrorMessage: String?
    @Published private(set) var exportErrorMessage: String?

    private let store: NotesStore
    private let persistenceQueue = DispatchQueue(
        label: "com.ranveer.droppy.notes-persistence",
        qos: .utility
    )
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var saveGeneration = 0

    init(store: NotesStore = NotesStore(), now: Date = Date()) {
        self.store = store
        selectedNoteID = nil
        switch store.load() {
        case .missing:
            notes = []
        case let .loaded(archive):
            notes = archive.notes
        case .failed:
            notes = []
            storageErrorMessage =
                "Saved notes could not be read. They were left untouched."
        }
        pruneTrash(now: now)
        selectedNoteID = activeNotes.first?.id
    }

    var activeNotes: [DroppyNote] {
        notes
            .filter { $0.deletedAt == nil }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var trashedNotes: [DroppyNote] {
        notes
            .filter { $0.deletedAt != nil }
            .sorted {
                ($0.deletedAt ?? .distantPast)
                    > ($1.deletedAt ?? .distantPast)
            }
    }

    var displayedNotes: [DroppyNote] {
        let source = isShowingTrash ? trashedNotes : activeNotes
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return source
        }
        return source.filter {
            $0.searchableContent.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedNote: DroppyNote? {
        notes.first { $0.id == selectedNoteID }
    }

    @discardableResult
    func createNote(at date: Date = Date()) -> DroppyNote {
        let note = DroppyNote(createdAt: date)
        var candidate = notes
        candidate.append(note)
        guard save(candidate) else {
            return note
        }
        isShowingTrash = false
        selectedNoteID = note.id
        return note
    }

    func select(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else {
            return
        }
        isShowingTrash = notes.first { $0.id == id }?.deletedAt != nil
        selectedNoteID = id
    }

    func updateSelectedTitle(_ title: String, at date: Date = Date()) {
        updateSelected(at: date) { $0.title = title }
    }

    func updateSelectedBody(_ body: String, at date: Date = Date()) {
        updateSelected(at: date) { $0.body = body }
    }

    func moveSelectedToTrash(at date: Date = Date()) {
        guard let selectedNoteID else { return }
        guard mutate({ notes in
            guard let index = notes.firstIndex(where: {
                $0.id == selectedNoteID
            }) else {
                return
            }
            notes[index].deletedAt = date
            notes[index].modifiedAt = date
        }) else {
            return
        }
        selectFirstDisplayedNote()
    }

    func restoreSelected(at date: Date = Date()) {
        guard let selectedNoteID else { return }
        guard mutate({ notes in
            guard let index = notes.firstIndex(where: {
                $0.id == selectedNoteID
            }) else {
                return
            }
            notes[index].deletedAt = nil
            notes[index].modifiedAt = date
        }) else {
            return
        }
        isShowingTrash = false
        self.selectedNoteID = selectedNoteID
    }

    func exportSelected(to url: URL) throws {
        guard let selectedNote else {
            return
        }
        try Data(selectedNote.markdown.utf8).write(to: url, options: .atomic)
        exportErrorMessage = nil
    }

    func reportExportError(_ error: Error) {
        exportErrorMessage = "Silverdeck could not export this note."
    }

    func pruneTrash(now: Date = Date()) {
        let candidateNotes = notes.filter { note in
            guard let deletedAt = note.deletedAt else {
                return true
            }
            return now.timeIntervalSince(deletedAt) < Self.trashLifetime
        }
        guard candidateNotes != notes else {
            return
        }
        let candidate = NotesArchive(notes: candidateNotes)
        if store.save(candidate) {
            notes = candidateNotes
        } else {
            storageErrorMessage = "Silverdeck could not clean up expired notes."
        }
    }

    private func updateSelected(
        at date: Date,
        mutation: (inout DroppyNote) -> Void
    ) {
        guard
            let selectedNoteID,
            let index = notes.firstIndex(where: { $0.id == selectedNoteID }),
            notes[index].deletedAt == nil
        else {
            return
        }
        var candidate = notes
        mutation(&candidate[index])
        candidate[index].modifiedAt = date
        notes = candidate
        storageErrorMessage = nil
        scheduleSave(candidate)
    }

    @discardableResult
    func flushPendingSave() -> Bool {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        saveGeneration += 1
        let archive = NotesArchive(notes: notes)
        let saved = persistenceQueue.sync {
            store.save(archive)
        }
        storageErrorMessage = saved
            ? nil
            : "Silverdeck could not save your notes."
        return saved
    }

    @discardableResult
    private func mutate(
        _ mutation: (inout [DroppyNote]) -> Void
    ) -> Bool {
        var candidate = notes
        mutation(&candidate)
        return save(candidate)
    }

    @discardableResult
    private func save(_ candidate: [DroppyNote]) -> Bool {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        saveGeneration += 1
        let archive = NotesArchive(notes: candidate)
        let saved = persistenceQueue.sync {
            store.save(archive)
        }
        if saved {
            notes = candidate
            storageErrorMessage = nil
            return true
        } else {
            storageErrorMessage = "Silverdeck could not save your notes."
            return false
        }
    }

    private func scheduleSave(_ candidate: [DroppyNote]) {
        pendingSaveWorkItem?.cancel()
        saveGeneration += 1
        let generation = saveGeneration
        let archive = NotesArchive(notes: candidate)
        let store = self.store
        let workItem = DispatchWorkItem { [weak self] in
            let saved = store.save(archive)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == saveGeneration else {
                    return
                }
                pendingSaveWorkItem = nil
                storageErrorMessage = saved
                    ? nil
                    : "Silverdeck could not save your notes."
            }
        }
        pendingSaveWorkItem = workItem
        persistenceQueue.asyncAfter(
            deadline: .now() + 0.35,
            execute: workItem
        )
    }

    private func selectFirstDisplayedNote() {
        let validIDs = Set(displayedNotes.map(\.id))
        if let selectedNoteID, validIDs.contains(selectedNoteID) {
            return
        }
        selectedNoteID = displayedNotes.first?.id
    }
}

struct NotesView: View {
    @ObservedObject var feature: NotesFeature

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            if let error = feature.storageErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            if let error = feature.exportErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }

            if let note = feature.selectedNote {
                editor(note)
            } else {
                emptyState
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker(
                    "Location",
                    selection: $feature.isShowingTrash
                ) {
                    Label("Notes", systemImage: "note.text")
                        .tag(false)
                    Label("Trash", systemImage: "trash")
                        .tag(true)
                }
                .pickerStyle(.segmented)

                Button {
                    feature.createNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("New note")
            }

            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search notes", text: $feature.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    .thinMaterial,
                    in: RoundedRectangle(cornerRadius: 7)
                )

                Picker("Note", selection: $feature.selectedNoteID) {
                    ForEach(feature.displayedNotes) { note in
                        Text(note.title.isEmpty ? "Untitled Note" : note.title)
                            .tag(Optional(note.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
            }
        }
    }

    private func editor(_ note: DroppyNote) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if feature.isShowingTrash {
                    Text(note.title.isEmpty ? "Untitled Note" : note.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                } else {
                    TextField(
                        "Note title",
                        text: Binding(
                            get: { feature.selectedNote?.title ?? "" },
                            set: { feature.updateSelectedTitle($0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                }

                Spacer()

                if feature.isShowingTrash {
                    Button {
                        feature.restoreSelected()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .help("Restore note")
                } else {
                    Button {
                        exportNote(note)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .help("Export note")

                    Button {
                        feature.moveSelectedToTrash()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Move note to Trash")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if feature.isShowingTrash {
                ScrollView {
                    Text(note.body)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                }
            } else {
                TextEditor(
                    text: Binding(
                        get: { feature.selectedNote?.body ?? "" },
                        set: { feature.updateSelectedBody($0) }
                    )
                )
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: feature.isShowingTrash ? "trash" : "note.text")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(feature.isShowingTrash ? "Trash is empty" : "No notes yet")
                .font(.system(size: 14, weight: .semibold))
            if !feature.isShowingTrash {
                Button("New Note") {
                    feature.createNote()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportNote(_ note: DroppyNote) {
        let panel = NSSavePanel()
        panel.title = "Export Note"
        panel.nameFieldStringValue = note.exportFileName
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try feature.exportSelected(to: url)
        } catch {
            feature.reportExportError(error)
        }
    }
}
