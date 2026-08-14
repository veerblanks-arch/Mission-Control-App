import AppKit
import Combine
import SwiftUI

enum UnifiedSearchSource: String, CaseIterable {
    case clipboard
    case shelf
    case files
    case notes

    var title: String {
        rawValue.capitalized
    }

    var symbolName: String {
        switch self {
        case .clipboard:
            return "doc.on.clipboard"
        case .shelf:
            return "tray"
        case .files:
            return "folder"
        case .notes:
            return "note.text"
        }
    }
}

enum UnifiedSearchTarget: Equatable {
    case clipboard(UUID)
    case shelf(UUID)
    case file(URL)
    case note(UUID)
}

struct UnifiedSearchResult: Identifiable, Equatable {
    let id: String
    let source: UnifiedSearchSource
    let target: UnifiedSearchTarget
    let title: String
    let subtitle: String
    let relevance: Int
}

@MainActor
final class UnifiedSearchFeature: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refresh()
        }
    }
    @Published private(set) var results: [UnifiedSearchResult] = []
    @Published private(set) var isSearchingFiles = false

    private let clipboard: ClipboardManagerFeature
    private let shelf: ShelfFeature
    private let files: FileFinderFeature
    private let notes: NotesFeature
    private var generation = 0
    private var fileSearchToken: FileFinderScanToken?

    init(
        clipboard: ClipboardManagerFeature,
        shelf: ShelfFeature,
        files: FileFinderFeature,
        notes: NotesFeature
    ) {
        self.clipboard = clipboard
        self.shelf = shelf
        self.files = files
        self.notes = notes
    }

    func refresh() {
        fileSearchToken?.cancel()
        generation += 1
        let currentGeneration = generation
        let token = FileFinderScanToken()
        fileSearchToken = token
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedQuery.isEmpty else {
            results = []
            isSearchingFiles = false
            return
        }

        let nonFileResults = makeNonFileResults(query: normalizedQuery)
        results = nonFileResults
        isSearchingFiles = true
        let rootURL = files.selectedDirectoryURL

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fileResults = FileFinderScanner.scan(
                rootURL: rootURL,
                query: normalizedQuery,
                maximumResults: 24,
                isCancelled: { token.isCancelled }
            ).map { item in
                UnifiedSearchResult(
                    id: "file-\(item.id)",
                    source: .files,
                    target: .file(item.url),
                    title: item.displayName,
                    subtitle: item.parentPath,
                    relevance: Self.relevance(
                        title: item.displayName,
                        metadata: item.parentPath,
                        query: normalizedQuery
                    )
                )
            }

            DispatchQueue.main.async {
                guard
                    let self,
                    currentGeneration == self.generation
                else {
                    return
                }
                self.results = Self.sorted(nonFileResults + fileResults)
                self.isSearchingFiles = false
            }
        }
    }

    func clear() {
        query = ""
    }

    private func makeNonFileResults(
        query: String
    ) -> [UnifiedSearchResult] {
        let clipboardMatches = clipboard.items.compactMap {
            item -> UnifiedSearchResult? in
            guard item.searchableContent.localizedCaseInsensitiveContains(
                query
            ) else {
                return nil
            }
            return UnifiedSearchResult(
                id: "clipboard-\(item.id.uuidString)",
                source: .clipboard,
                target: .clipboard(item.id),
                title: item.title,
                subtitle: item.sourceAppName,
                relevance: Self.relevance(
                    title: item.title,
                    metadata: item.searchableContent,
                    query: query
                )
            )
        }
        let clipboardResults = Array(
            Self.topResults(clipboardMatches, maximum: 12)
        )

        let shelfMatches = shelf.items.compactMap {
            item -> UnifiedSearchResult? in
            let metadata = "\(item.displayName)\n\(item.lastKnownPath)"
            guard metadata.localizedCaseInsensitiveContains(query) else {
                return nil
            }
            return UnifiedSearchResult(
                id: "shelf-\(item.id.uuidString)",
                source: .shelf,
                target: .shelf(item.id),
                title: item.displayName,
                subtitle: item.parentPath,
                relevance: Self.relevance(
                    title: item.displayName,
                    metadata: metadata,
                    query: query
                )
            )
        }
        let shelfResults = Self.topResults(shelfMatches, maximum: 12)

        let noteMatches = notes.activeNotes.compactMap {
            note -> UnifiedSearchResult? in
            guard note.searchableContent.localizedCaseInsensitiveContains(
                query
            ) else {
                return nil
            }
            return UnifiedSearchResult(
                id: "note-\(note.id.uuidString)",
                source: .notes,
                target: .note(note.id),
                title: note.title.isEmpty ? "Untitled Note" : note.title,
                subtitle: note.body
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                relevance: Self.relevance(
                    title: note.title,
                    metadata: note.body,
                    query: query
                )
            )
        }
        let noteResults = Self.topResults(noteMatches, maximum: 12)

        return Self.sorted(
            clipboardResults + shelfResults + noteResults
        )
    }

    nonisolated static func relevance(
        title: String,
        metadata: String,
        query: String
    ) -> Int {
        if title.caseInsensitiveCompare(query) == .orderedSame {
            return 400
        }
        if title.lowercased().hasPrefix(query.lowercased()) {
            return 300
        }
        if title.localizedCaseInsensitiveContains(query) {
            return 200
        }
        if metadata.localizedCaseInsensitiveContains(query) {
            return 100
        }
        return 0
    }

    nonisolated static func sorted(
        _ results: [UnifiedSearchResult]
    ) -> [UnifiedSearchResult] {
        results.sorted { lhs, rhs in
            if lhs.relevance != rhs.relevance {
                return lhs.relevance > rhs.relevance
            }
            if lhs.source != rhs.source {
                let lhsIndex = UnifiedSearchSource.allCases.firstIndex(
                    of: lhs.source
                ) ?? 0
                let rhsIndex = UnifiedSearchSource.allCases.firstIndex(
                    of: rhs.source
                ) ?? 0
                return lhsIndex < rhsIndex
            }
            return lhs.title.localizedStandardCompare(rhs.title)
                == .orderedAscending
        }
    }

    nonisolated static func topResults(
        _ results: [UnifiedSearchResult],
        maximum: Int
    ) -> [UnifiedSearchResult] {
        Array(sorted(results).prefix(maximum))
    }
}

struct UnifiedSearchView: View {
    @ObservedObject var feature: UnifiedSearchFeature
    @ObservedObject var model: OverlayPanelModel
    @ObservedObject var clipboard: ClipboardManagerFeature
    @ObservedObject var shelf: ShelfFeature
    @ObservedObject var notes: NotesFeature

    var body: some View {
        Group {
            if feature.query.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                emptyPrompt
            } else if feature.results.isEmpty && feature.isSearchingFiles {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if feature.results.isEmpty {
                noResults
            } else {
                resultList
            }
        }
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(UnifiedSearchSource.allCases, id: \.self) { source in
                    let sourceResults = feature.results.filter {
                        $0.source == source
                    }
                    if !sourceResults.isEmpty {
                        HStack {
                            Label(source.title, systemImage: source.symbolName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 6)

                        ForEach(sourceResults) { result in
                            Button {
                                activate(result)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: source.symbolName)
                                        .frame(width: 24)
                                        .foregroundStyle(.secondary)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.title)
                                            .font(.system(
                                                size: 12,
                                                weight: .semibold
                                            ))
                                            .lineLimit(1)
                                        Text(result.subtitle)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                .thinMaterial,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var emptyPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Search Silverdeck")
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No results")
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func activate(_ result: UnifiedSearchResult) {
        switch result.target {
        case let .clipboard(id):
            guard let item = clipboard.items.first(where: { $0.id == id }) else {
                return
            }
            model.closeTemporarySurfaces()
            clipboard.activate(item)
        case let .shelf(id):
            guard let item = shelf.items.first(where: { $0.id == id }) else {
                return
            }
            shelf.open(item)
        case let .file(url):
            NSWorkspace.shared.open(url)
        case let .note(id):
            notes.select(id)
            model.showFeature(.notes)
        }
    }
}
