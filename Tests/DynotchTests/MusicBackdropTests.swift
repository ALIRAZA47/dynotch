import AppKit
import SwiftUI
import Testing
@testable import Dynotch

/// The Music section's ground: the cover, dimmed just far enough for its second lines to read.
@MainActor
struct MusicBackdropTests {
    private let ink = MusicInk.theme(from: .standard)

    private func cover(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
    }

    /// The contrast of the ink's second lines on `color` dimmed as the backdrop dims it.
    private func contrast(on color: NSColor) -> Double {
        let amount = MusicBackdrop.dimming(for: cover(color))
        let rgb = Luminance.rgb(of: color)!
        let base = Luminance.rgb(of: NSColor(ink.background))!
        let ground = Luminance.of(zip(rgb, base).map { $0 * (1 - amount) + $1 * amount })
        return NotchTheme.contrast(NotchTheme.luminance(of: ink.secondary), ground)
    }

    @Test func secondLinesReadOnAnyCover() {
        let covers: [NSColor] = [.white, .black, .yellow, .cyan, .systemPink,
                                 NSColor(srgbRed: 0.98, green: 0.36, blue: 0.55, alpha: 1)]
        for color in covers {
            #expect(contrast(on: color) >= 4.5, "\(color)")
        }
    }

    @Test func darkCoversKeepTheirColor() {
        // A dark cover needs no dimming, so it gets only the least, and a white one nearly all.
        #expect(MusicBackdrop.dimming(for: cover(.black)) == 0.42)
        #expect(MusicBackdrop.dimming(for: cover(.white)) > 0.7)
    }
}
