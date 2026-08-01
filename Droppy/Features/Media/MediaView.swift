import AppKit
import SwiftUI

struct MiniMediaPlayerView: View {
    @ObservedObject var feature: MediaFeature
    let snapshot: MediaSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Button(action: feature.openMusicApplication) {
                miniArtwork
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .help("Open Apple Music")
            .accessibilityLabel("Open Apple Music")

            VStack(alignment: .leading, spacing: 1) {
                Button(action: feature.openMusicApplication) {
                    Text(nowPlayingLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Apple Music")
                .accessibilityLabel("Open \(nowPlayingLabel) in Apple Music")

                Slider(
                    value: Binding(
                        get: { snapshot.progress },
                        set: { feature.seek(toProgress: $0) }
                    ),
                    in: 0...1
                )
                .controlSize(.mini)
                .tint(Color(nsColor: snapshot.tintColor))
                .disabled(snapshot.duration <= 0)
                .accessibilityLabel("Playback position")
                .accessibilityValue(
                    "\(Int(snapshot.progress * 100)) percent"
                )
            }
            .frame(minWidth: 58)

            HStack(spacing: 0) {
                miniTransportButton(
                    symbol: "backward.fill",
                    label: "Previous Track",
                    action: feature.previousTrack
                )
                miniTransportButton(
                    symbol: snapshot.isPlaying ? "pause.fill" : "play.fill",
                    label: snapshot.isPlaying ? "Pause" : "Play",
                    action: feature.togglePlayPause
                )
                miniTransportButton(
                    symbol: "forward.fill",
                    label: "Next Track",
                    action: feature.nextTrack
                )
            }
            .fixedSize()

            if let message = feature.controlMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 14, height: 30)
                    .help(message)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Apple Music control warning")
                    .accessibilityValue(message)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Color(nsColor: snapshot.tintColor).opacity(0.08)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing from Apple Music")
    }

    private var nowPlayingLabel: String {
        snapshot.artist.isEmpty
            ? snapshot.title
            : "\(snapshot.title) — \(snapshot.artist)"
    }

    private var miniArtwork: some View {
        Group {
            if let artwork = snapshot.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(nsColor: snapshot.tintColor).opacity(0.18)
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            Color(nsColor: snapshot.tintColor)
                        )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func miniTransportButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
