import Foundation
import Testing
@testable import MoneyPrinter

struct RebalanceTests {
    private func order(_ cashFraction: Double, confidence: Double = 1, cash: Int, held: Int, price: Int) -> RebalanceOrder.Action {
        Rebalance.order(cashFraction: cashFraction, confidence: confidence, cash: cash, held: held, price: price).action
    }

    @Test func buysUpToTarget() {
        #expect(order(0, cash: 1_000_000, held: 0, price: 10_000) == .buy(100))
        #expect(order(0.35, cash: 500_000, held: 500, price: 1_000) == .buy(150))
    }

    @Test func sellsDownToTarget() {
        #expect(order(1, cash: 0, held: 3, price: 1_000) == .sell(3))
    }

    @Test func holdsInsideBand() {
        #expect(order(0.5, cash: 500_000, held: 50, price: 10_000) == .hold("목표와 같습니다."))
        #expect(order(0.497, cash: 500_000, held: 500, price: 1_000) == .hold("차이가 계좌의 10% 미만입니다."))
        #expect(order(0.45, cash: 500_000, held: 500, price: 1_000) == .hold("차이가 계좌의 10% 미만입니다."))
    }

    @Test func holdsWhenCashCannotBuyOneShare() {
        #expect(order(0, cash: 9_000, held: 0, price: 10_000) == .hold("목표와 같습니다."))
    }

    @Test func holdsWhenConfidenceIsLow() {
        #expect(order(0, confidence: 0.4, cash: 1_000_000, held: 0, price: 10_000) == .hold("confidence가 0.5 미만이라 주문하지 않습니다."))
        #expect(order(0, confidence: 0.6, cash: 1_000_000, held: 0, price: 10_000) == .buy(100))
    }

    @Test func marketHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Seoul"))
        let open = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10)))
        let closed = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15, minute: 20)))
        let sunday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 10)))
        #expect(Rebalance.marketIsOpen(open, calendar: calendar))
        #expect(!Rebalance.marketIsOpen(closed, calendar: calendar))
        #expect(!Rebalance.marketIsOpen(sunday, calendar: calendar))
    }
}
