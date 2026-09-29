import AppKit
import SwiftUI

enum LexiStyle {
    static let accent = Color(nsColor: NSColor(name: "LexiNoteAccent") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.63, green: 0.78, blue: 0.67, alpha: 1)
        }
        return NSColor(srgbRed: 0.18, green: 0.36, blue: 0.28, alpha: 1)
    })

    static let softAccent = accent.opacity(0.10)
    static let page = Color(nsColor: .textBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let rule = Color(nsColor: .separatorColor)

    static func word(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }
}
