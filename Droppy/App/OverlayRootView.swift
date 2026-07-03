import SwiftUI

struct OverlayRootView: View {
    @State private var selectedFeature: OverlayFeature = .clipboard

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("Feature", selection: $selectedFeature) {
                ForEach(OverlayFeature.allCases) { feature in
                    Label(feature.title, systemImage: feature.symbolName)
                        .tag(feature)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            Divider()

            featurePlaceholder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 360, minHeight: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
                Text("Menu-bar overlay shell")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private var featurePlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: selectedFeature.symbolName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(selectedFeature.title)
                .font(.system(size: 20, weight: .semibold))

            Text(selectedFeature.phaseZeroMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .frame(maxWidth: 280)
        }
        .padding(24)
    }
}

private enum OverlayFeature: String, CaseIterable, Identifiable {
    case clipboard
    case shelf
    case basket
    case media

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard:
            return "Clipboard"
        case .shelf:
            return "Shelf"
        case .basket:
            return "Basket"
        case .media:
            return "Media"
        }
    }

    var symbolName: String {
        switch self {
        case .clipboard:
            return "doc.on.clipboard"
        case .shelf:
            return "tray.and.arrow.down"
        case .basket:
            return "basket"
        case .media:
            return "play.rectangle"
        }
    }

    var phaseZeroMessage: String {
        switch self {
        case .clipboard:
            return "Phase 1 will add searchable clipboard history and the Cmd-Shift-V opener."
        case .shelf:
            return "Phase 2 will add local file stashing and drag-out support."
        case .basket:
            return "Phase 3 will add the drag gesture drop zone."
        case .media:
            return "Phase 4 will bring back artwork-tinted media controls in this panel."
        }
    }
}
