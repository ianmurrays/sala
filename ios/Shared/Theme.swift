import SwiftUI
import UIKit

// MARK: - Theme

extension Color {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let salaAccent = dynamic(light: 0x0062CC, dark: 0x4C9EFF)
    static let sickText = dynamic(light: 0xB23F00, dark: 0xFF9F66)
    static let sickFill = dynamic(light: 0xFDEBDF, dark: 0x4A2210)
    static let sickButton = dynamic(light: 0xB23F00, dark: 0xD9621F)
    static let presentText = dynamic(light: 0x1B6B33, dark: 0x7EDC97)
    static let presentFill = dynamic(light: 0xE3F5E8, dark: 0x173D22)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let screen = Color(uiColor: .systemGroupedBackground)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Child {
    /// The status pill's text and fill colours, on Today and in the widgets.
    var statusColors: (text: Color, fill: Color) {
        switch status {
        case "present": (.presentText, .presentFill)
        case "sick": (.sickText, .sickFill)
        default: (.secondary, Color(uiColor: .tertiarySystemFill))
        }
    }
}
