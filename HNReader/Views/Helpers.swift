import SwiftUI

// MARK: - Theme

extension Color {
    /// HN orange: #f97316
    static let hnOrange = Color(red: 0xF9 / 255, green: 0x73 / 255, blue: 0x16 / 255)
}

// MARK: - View Modifiers

extension View {
    /// Shows a pointing hand cursor on hover (macOS).
    func pointerOnHover() -> some View {
        self.onHover { inside in
            if inside { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}
