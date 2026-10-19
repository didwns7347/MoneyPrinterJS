import Foundation

struct RebalanceOrder: Equatable {
    enum Action: Equatable {
        case buy(Int)
        case sell(Int)
        case hold(String)
    }

    let action: Action
    let price: Int
    let held: Int
    let cash: Int
    let targetQuantity: Int

    var summary: String {
        switch action {
        case .buy(let quantity): "\(quantity)주 매수"
        case .sell(let quantity): "\(quantity)주 매도"
        case .hold(let reason): reason
        }
    }

    var sendsOrder: Bool {
        switch action {
        case .buy, .sell: true
        case .hold: false
        }
    }
}

enum Rebalance {
    /// 평가금액 대비 이 비율 미만이면 주문하지 않습니다.
    static let minMove = 0.10
    /// Jev 평균 confidence가 이 값 미만이면 주문하지 않습니다.
    static let minConfidence = 0.5

    static func order(cashFraction: Double, confidence: Double, cash: Int, held: Int, price: Int) -> RebalanceOrder {
        func hold(_ reason: String, target: Int = held) -> RebalanceOrder {
            RebalanceOrder(action: .hold(reason), price: price, held: held, cash: cash, targetQuantity: target)
        }
        guard price > 0, cash >= 0, held >= 0 else { return hold("가격이 없습니다.") }
        guard confidence >= minConfidence else { return hold("confidence가 0.5 미만이라 주문하지 않습니다.") }

        let portfolio = cash + held * price
        let target = targetShares(portfolio: portfolio, cashFraction: cashFraction, cash: cash, held: held, price: price)
        let delta = target - held
        guard delta != 0 else { return hold("목표와 같습니다.", target: target) }
        guard moveFraction(delta: delta, price: price, portfolio: portfolio) >= minMove else {
            return hold("차이가 계좌의 10% 미만입니다.", target: target)
        }

        let action: RebalanceOrder.Action = delta > 0 ? .buy(delta) : .sell(-delta)
        return RebalanceOrder(action: action, price: price, held: held, cash: cash, targetQuantity: target)
    }

    private static func targetShares(portfolio: Int, cashFraction: Double, cash: Int, held: Int, price: Int) -> Int {
        let stockFraction = min(max(1 - cashFraction, 0), 1)
        let targetValue = Double(portfolio) * stockFraction
        let desired = Int((targetValue / Double(price)).rounded(.down))
        return min(desired, held + cash / price)
    }

    private static func moveFraction(delta: Int, price: Int, portfolio: Int) -> Double {
        abs(Double(delta * price)) / Double(max(portfolio, 1))
    }

    /// 평일 09:00–15:20 서울. 휴장일은 구분하지 않습니다.
    static func marketIsOpen(_ date: Date = Date(), calendar: Calendar = seoul) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        guard (2 ... 6).contains(weekday) else { return false }
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return minutes >= 9 * 60 && minutes < 15 * 60 + 20
    }

    static func integer(_ text: String?) -> Int {
        guard let text else { return 0 }
        let trimmed = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if let value = Int(trimmed) { return max(value, 0) }
        guard let value = Double(trimmed), value >= 0 else { return 0 }
        return Int(value.rounded(.down))
    }

    private static let seoul: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        return calendar
    }()
}

struct DomesticCashOrderReceipt: Equatable {
    let orderNumber: String
    let orderTime: String
}

struct HashKeyResponse: Decodable {
    let hash: String

    enum CodingKeys: String, CodingKey {
        case hash = "HASH"
    }
}

struct DomesticCashOrderResponse: Decodable {
    let output: Output?
    let returnCode: String
    let message: String

    struct Output: Decodable {
        let orderNumber: String
        let orderTime: String

        enum CodingKeys: String, CodingKey {
            case orderNumber = "ODNO"
            case orderTime = "ORD_TMD"
        }
    }

    enum CodingKeys: String, CodingKey {
        case output
        case returnCode = "rt_cd"
        case message = "msg1"
    }

    var isSuccess: Bool { returnCode == "0" }
}

enum OrderError: LocalizedError {
    case invalidQuantity
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidQuantity: "주문 수량이 없습니다."
        case .rejected(let message): message.isEmpty ? "주문이 거절되었습니다." : message
        }
    }
}
