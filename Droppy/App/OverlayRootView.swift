import AppKit
import SwiftUI

struct OverlayRootView: View {
    @ObservedObject var model: OverlayPanelModel
    @ObservedObject var clipboardManager: ClipboardManagerFeature
    @State private var clipboardSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ClipboardManagerView(
                manager: clipboardManager,
                searchText: $clipboardSearchText
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 360, minHeight: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Droppy")
                    .font(.system(size: 18, weight: .semibold))
                Text(model.selectedFeature.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }
}

struct ClipboardManagerView: View {
    @ObservedObject var manager: ClipboardManagerFeature
    @Binding var searchText: String

    private var filteredItems: [ClipboardItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return manager.items
        }

        return manager.items.filter { item in
            item.title.lowercased().contains(query)
                || item.subtitle.lowercased().contains(query)
                || item.sourceApp.lowercased().contains(query)
                || item.text?.lowercased().contains(query) == true
                || item.filePaths.contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            if filteredItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredItems) { item in
                            ClipboardItemRow(item: item) {
                                manager.copy(item)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search clipboard", text: $searchText)
                .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "Copy something to start history" : "No matching clipboard items")
                .font(.system(size: 15, weight: .semibold))
            Text("Droppy watches the local pasteboard while it is running.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct ClipboardItemRow: View {
    let item: ClipboardItem
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 12) {
                preview

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        Spacer()

                        Text(item.formattedTime)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Text(item.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(item.sourceApp)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 42, height: 42)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .file:
            Image(systemName: "doc")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 42, height: 42)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .image:
            if let data = item.imagePNGData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.purple)
                    .frame(width: 42, height: 42)
                    .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

enum OverlayFeature: String, Identifiable {
    case clipboard

    var id: String { rawValue }

    var title: String {
        "Clipboard"
    }

    var symbolName: String {
        "doc.on.clipboard"
    }

    var subtitle: String {
        "Clipboard history"
    }
}
