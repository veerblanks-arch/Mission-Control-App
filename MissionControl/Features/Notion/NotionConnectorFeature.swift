import AppKit
import SwiftUI

struct NotionShortcut: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var urlString: String

    init(id: UUID = UUID(), title: String, urlString: String) {
        self.id = id
        self.title = title
        self.urlString = urlString
    }
}

@MainActor
final class NotionConnectorFeature: ObservableObject {
    static let shared = NotionConnectorFeature()

    @Published private(set) var shortcuts: [NotionShortcut]

    private static let storageKey = "notionConnectorShortcuts"
    private static let calendarBundleIdentifier = "com.cron.electron"
    private static let calendarWebURL = URL(string: "https://calendar.notion.so")!
    private static let notionHomeURL = URL(string: "https://www.notion.so")!

    private let defaults: UserDefaults
    private let workspace: NSWorkspace

    init(defaults: UserDefaults = .standard, workspace: NSWorkspace = .shared) {
        self.defaults = defaults
        self.workspace = workspace

        if
            let data = defaults.data(forKey: Self.storageKey),
            let saved = try? JSONDecoder().decode([NotionShortcut].self, from: data)
        {
            shortcuts = saved
        } else {
            shortcuts = []
        }
    }

    @discardableResult
    func addShortcut(title: String, urlString: String) -> Bool {
        guard
            let normalizedTitle = Self.normalizedTitle(title),
            let normalizedURL = Self.normalizedURLString(urlString)
        else {
            return false
        }

        shortcuts.append(
            NotionShortcut(title: normalizedTitle, urlString: normalizedURL)
        )
        save()
        return true
    }

    @discardableResult
    func updateShortcut(id: UUID, title: String, urlString: String) -> Bool {
        guard
            let index = shortcuts.firstIndex(where: { $0.id == id }),
            let normalizedTitle = Self.normalizedTitle(title),
            let normalizedURL = Self.normalizedURLString(urlString)
        else {
            return false
        }

        shortcuts[index].title = normalizedTitle
        shortcuts[index].urlString = normalizedURL
        save()
        return true
    }

    func removeShortcut(id: UUID) {
        shortcuts.removeAll { $0.id == id }
        save()
    }

    func openCalendar() {
        if let applicationURL = workspace.urlForApplication(
            withBundleIdentifier: Self.calendarBundleIdentifier
        ) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            return
        }

        workspace.open(Self.calendarWebURL)
    }

    func openNotionHome() {
        workspace.open(Self.notionHomeURL)
    }

    func open(_ shortcut: NotionShortcut) {
        guard let url = URL(string: shortcut.urlString) else {
            return
        }
        workspace.open(url)
    }

    static func normalizedURLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard
            let url = URL(string: candidate),
            let scheme = url.scheme?.lowercased(),
            ["http", "https", "notion"].contains(scheme)
        else {
            return nil
        }

        if scheme != "notion" && url.host?.isEmpty != false {
            return nil
        }

        return url.absoluteString
    }

    private static func normalizedTitle(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(shortcuts) else {
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}

struct NotionConnectorView: View {
    @ObservedObject var feature: NotionConnectorFeature
    @State private var editorContext: NotionShortcutEditorContext?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                quickActions

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your shortcuts")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Workspaces, databases, and pages")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        editorContext = NotionShortcutEditorContext(shortcut: nil)
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if feature.shortcuts.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(feature.shortcuts) { shortcut in
                            shortcutRow(shortcut)
                        }
                    }
                }
            }
            .padding(18)
        }
        .sheet(item: $editorContext) { context in
            NotionShortcutEditor(
                shortcut: context.shortcut,
                onSave: { title, urlString in
                    if let shortcut = context.shortcut {
                        return feature.updateShortcut(
                            id: shortcut.id,
                            title: title,
                            urlString: urlString
                        )
                    }
                    return feature.addShortcut(title: title, urlString: urlString)
                }
            )
        }
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            quickAction(
                title: "Calendar",
                subtitle: "Open Notion Calendar",
                symbolName: "calendar",
                action: feature.openCalendar
            )
            quickAction(
                title: "Notion",
                subtitle: "Open your home",
                symbolName: "square.grid.2x2",
                action: feature.openNotionHome
            )
        }
    }

    private func quickAction(
        title: String,
        subtitle: String,
        symbolName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Add your first Notion shortcut")
                .font(.system(size: 13, weight: .semibold))
            Text("Paste a workspace, database, or page link for one-click access.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 20)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private func shortcutRow(_ shortcut: NotionShortcut) -> some View {
        Button {
            feature.open(shortcut)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 7)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(shortcut.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(shortcut.urlString)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") {
                editorContext = NotionShortcutEditorContext(shortcut: shortcut)
            }

            Divider()

            Button("Remove", role: .destructive) {
                feature.removeShortcut(id: shortcut.id)
            }
        }
    }
}

private struct NotionShortcutEditorContext: Identifiable {
    let id = UUID()
    let shortcut: NotionShortcut?
}

private struct NotionShortcutEditor: View {
    let shortcut: NotionShortcut?
    let onSave: (String, String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var urlString: String
    @State private var showsValidationError = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case url
    }

    init(
        shortcut: NotionShortcut?,
        onSave: @escaping (String, String) -> Bool
    ) {
        self.shortcut = shortcut
        self.onSave = onSave
        _title = State(initialValue: shortcut?.title ?? "")
        _urlString = State(initialValue: shortcut?.urlString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(shortcut == nil ? "Add Notion Shortcut" : "Edit Notion Shortcut")
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("School, Projects, Tasks…", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Notion link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("https://www.notion.so/…", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .url)
            }

            if showsValidationError {
                Text("Enter a name and a valid web or notion:// link.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(shortcut == nil ? "Add" : "Save") {
                    if onSave(title, urlString) {
                        dismiss()
                    } else {
                        showsValidationError = true
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            focusedField = title.isEmpty ? .title : .url
        }
    }
}
