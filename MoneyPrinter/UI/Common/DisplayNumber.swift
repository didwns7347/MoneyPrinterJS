import SwiftUI

enum QuoteTone {
    static func color(_ value: Double?) -> Color {
        guard let value, value != 0 else { return Theme.foreground }
        return value > 0 ? Theme.positive : Theme.negative
    }
}

enum DisplayNumber {
    static func value(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: ""))
    }

    static func won(_ raw: String) -> String {
        guard let number = value(raw) else { return raw }
        return (plain(number, digits: number.rounded() == number ? 0 : 2) ?? raw) + "원"
    }

    static func quantity(_ raw: String) -> String {
        guard let number = value(raw) else { return raw }
        return plain(number, digits: number.rounded() == number ? 0 : 4) ?? raw
    }

    static func signed(_ raw: String, suffix: String) -> String {
        guard let number = value(raw) else { return raw }
        let body = plain(abs(number), digits: 2) ?? raw
        let sign = number > 0 ? "+" : (number < 0 ? "-" : "")
        return sign + body + suffix
    }

    static func percent(_ value: Double) -> String {
        let body = plain(abs(value), digits: 2) ?? String(format: "%.2f", abs(value))
        let sign = value > 0 ? "+" : (value < 0 ? "-" : "")
        return sign + body + "%"
    }

    /// 0...1 비중을 부호 없는 퍼센트로. 0.25 → "25.0%"
    static func fraction(_ value: Double) -> String {
        decimal(value * 100, digits: 1) + "%"
    }

    static func decimal(_ value: Double, digits: Int) -> String {
        plain(value, digits: digits) ?? String(format: "%.\(digits)f", value)
    }

    private static func plain(_ number: Double, digits: Int) -> String? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: number))
    }
}
