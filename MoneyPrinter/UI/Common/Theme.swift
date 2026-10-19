import SwiftUI

enum Theme {
    static let background = Color(red: 0x02 / 255, green: 0x06 / 255, blue: 0x17 / 255)
    static let card = Color(red: 0x0E / 255, green: 0x12 / 255, blue: 0x23 / 255)
    static let surfaceMuted = Color(red: 0x1A / 255, green: 0x1E / 255, blue: 0x2F / 255)
    static let border = Color(red: 0x33 / 255, green: 0x41 / 255, blue: 0x55 / 255)
    static let foreground = Color(red: 0xF8 / 255, green: 0xFA / 255, blue: 0xFC / 255)
    static let muted = Color(red: 0x94 / 255, green: 0xA3 / 255, blue: 0xB8 / 255)
    static let accent = Color(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255)
    static let positive = Color(red: 0xF8 / 255, green: 0x71 / 255, blue: 0x71 / 255)
    static let negative = Color(red: 0x60 / 255, green: 0xA5 / 255, blue: 0xFA / 255)
    static let danger = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)

    static let heroFont = Font.system(.title2, design: .monospaced).weight(.bold)
    static let headlineFont = Font.system(.headline, design: .rounded)
    static let metricFont = Font.system(.body, design: .monospaced).weight(.medium)
    static let captionMetricFont = Font.system(.caption, design: .monospaced)
}

extension View {
    func dashboardList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.background)
    }

    func dashboardScreen() -> some View {
        background(Theme.background)
    }
}
