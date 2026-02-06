import SwiftUI

struct CodexTheme {
    static let canvas = Color(nsColor: NSColor(red: 0.96, green: 0.965, blue: 0.975, alpha: 1.0))
    static let panel = Color(nsColor: NSColor(red: 0.985, green: 0.988, blue: 0.995, alpha: 1.0))
    static let panelSubtle = Color(nsColor: NSColor(red: 0.992, green: 0.994, blue: 0.998, alpha: 1.0))
    static let border = Color(nsColor: NSColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 1.0))
    static let borderSoft = Color(nsColor: NSColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 0.45))
    static let textPrimary = Color(nsColor: NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0))
    static let textSecondary = Color(nsColor: NSColor(red: 0.38, green: 0.42, blue: 0.50, alpha: 1.0))
    static let accent = Color(nsColor: NSColor(red: 0.14, green: 0.45, blue: 0.90, alpha: 1.0))
    static let userBubble = Color(nsColor: NSColor(red: 0.90, green: 0.94, blue: 1.0, alpha: 1.0))
    static let assistantBubble = Color.white
    static let warning = Color(nsColor: NSColor.systemOrange)
    static let danger = Color(nsColor: NSColor.systemRed)
    static let success = Color(nsColor: NSColor.systemGreen)

    // Chat surface tokens.
    static let chatMaxColumnWidth: CGFloat = 710
    static let chatRowSpacing: CGFloat = 14
    static let chatBodyFont = Font.system(size: 13, weight: .regular)
    static let chatMetaFont = Font.system(size: 10, weight: .medium)
    static let chatStatusFont = Font.system(size: 11, weight: .medium)
    static let chatChipFont = Font.system(size: 10, weight: .medium)
    static let chatChromeRadius: CGFloat = 10
    static let chatInlineRadius: CGFloat = 8
    static let chatComposerRadius: CGFloat = 10
    static let chatBorderLineWidth: CGFloat = 1
}
