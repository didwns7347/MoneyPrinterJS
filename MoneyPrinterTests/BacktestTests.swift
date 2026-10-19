import Foundation
import Testing
@testable import MoneyPrinter

struct BacktestTests {
    private let days = 5

    /// 1,000원부터 하루 10원씩 오르는 일봉.
    private func bars() -> [IndexDailyBar] {
        (0 ..< MarketSnapshot.requiredBarCount + days).map { index in
            let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: index, to: Date(timeIntervalSince1970: 1_700_000_000))!
            let ymd = date.formatted(.iso8601.year().month().day().dateSeparator(.omitted))
            let close = Double(1_000 + index * 10)
            return IndexDailyBar(date: ymd, close: close, high: close)
        }
    }

    @Test func allInMatchesBuyAndHold() async throws {
        let result = try await Backtest.simulate(bars: bars(), startingCash: 1_000_000) { _ in
            BacktestDecision(score: 0, confidence: 1)
        }
        #expect(result.count == days)
        #expect(result.first?.traded == true)
        #expect(result.dropFirst().allSatisfy { !$0.traded })
        #expect(result.allSatisfy { $0.equity == $0.buyHoldEquity })

        let summary = try #require(BacktestSummary(days: result, startingCash: 1_000_000))
        #expect(summary.tradeCount == 1)
        #expect(summary.returnPct > 0)
        #expect(summary.maxDrawdownPct == 0)
    }

    @Test func lowConfidenceNeverTrades() async throws {
        let result = try await Backtest.simulate(bars: bars(), startingCash: 1_000_000) { _ in
            BacktestDecision(score: 0, confidence: 0.4)
        }
        #expect(result.allSatisfy { !$0.traded && $0.equity == 1_000_000 })
        #expect(result.last.map { $0.buyHoldEquity > 1_000_000 } == true)
    }

    @Test func decisionsOnlySeePastBars() async throws {
        let all = bars()
        var seen: [String] = []
        _ = try await Backtest.simulate(bars: all, startingCash: 1_000_000) { snapshot in
            seen.append(snapshot.asOf)
            return BacktestDecision(score: 4, confidence: 1)
        }
        let decisionDays = all.dropLast().suffix(days).map { MarketSnapshot.isoDate($0.date) }
        #expect(seen == Array(decisionDays))
    }

    @Test func savedRunKeepsJevDecisions() async throws {
        let result = try await Backtest.simulate(bars: bars(), startingCash: 1_000_000) { _ in
            BacktestDecision(score: 1, confidence: 0.8, model: "jev-test", inputTokens: 42, responseJSON: "{}")
        }
        let run = BacktestRun(ticker: "069500", ranAt: Date(timeIntervalSince1970: 0), startingCash: 1_000_000, days: result)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BacktestRun.self, from: encoder.encode(run))

        #expect(decoded.days.count == days)
        #expect(decoded.days.first?.action == result.first?.action)
        let decision = try #require(decoded.days.last?.decision)
        #expect(decision.decisionDay == MarketSnapshot.isoDate(bars().dropLast().last!.date))
        #expect(decision.score == 1 && decision.confidence == 0.8)
        #expect(decision.model == "jev-test" && decision.inputTokens == 42 && decision.responseJSON == "{}")
    }

    @Test func maskedSnapshotHidesDateTickerAndPrice() throws {
        let snapshot = try MarketSnapshot(bars: bars(), ticker: "449180").masked()
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!json.contains("449180"))
        #expect(!json.contains("latest_closing_price"))
        #expect(snapshot.asOf.isEmpty)
    }
}
