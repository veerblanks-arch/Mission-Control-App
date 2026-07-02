import AppKit

struct MediaPlayerFeature {
    static let phase = 2

    // Phase 2 will tint media controls from currently playing artwork.
    var artworkTintColor: NSColor = .controlAccentColor
}
