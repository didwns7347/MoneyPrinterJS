import Foundation
import Testing
@testable import MoneyPrinter

struct MarketSnapshotTests {
    private func makeBars(
        count: Int = MarketSnapshot.requiredBarCount,
        close: (Int) -> Double = { _ in 100 },
        high: ((Int) -> Double)? = nil
    ) -> [IndexDailyBar] {
        (0 ..< count).map { index in
            let c = close(index)
            let h = high?(index) ?? c
            let year = 2025 + index / 300
            let month = (index % 300) / 28 + 1
            let day = (index % 28) + 1
            let date = String(format: "%04d%02d%02d", year, month, day)
            return IndexDailyBar(date: date, close: c, high: h)
        }
    }

    private func isClose(_ a: Double?, _ b: Double, accuracy: Double = 1e-9) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= accuracy
    }

    @Test func throwsWhenHistoryIsShort() {
        let bars = makeBars(count: MarketSnapshot.requiredBarCount - 1)
        #expect(throws: MarketSnapshotError.self) {
            try MarketSnapshot(bars: bars)
        }
    }

    @Test func throwsWhenPriceIsNonPositive() {
        var bars = makeBars()
        bars[10] = IndexDailyBar(date: bars[10].date, close: 0, high: 100)
        #expect(throws: MarketSnapshotError.self) {
            try MarketSnapshot(bars: bars)
        }
    }

    @Test func flatSeriesProducesZeroGapsAndZeroVolatility() throws {
        let bars = makeBars()
        let snapshot = try MarketSnapshot(bars: bars, ticker: "449180")
        #expect(snapshot.ticker == "449180")
        #expect(snapshot.latestClosingPrice == 100)
        #expect(isClose(snapshot.priceIndexed, 100))
        #expect(isClose(snapshot.priceVsMa20Pct, 0))
        #expect(isClose(snapshot.priceVsMa60Pct, 0))
        #expect(isClose(snapshot.priceVsMa200Pct, 0))
        #expect(isClose(snapshot.ma200Slope20dPct, 0))
        #expect(isClose(snapshot.ma20Slope5dPct, 0))
        #expect(isClose(snapshot.volatility20dPct, 0))
        #expect(isClose(snapshot.volatility60dPct, 0))
        #expect(isClose(snapshot.drawdownFrom200dHighPct, 0))
        #expect(isClose(snapshot.return1dPct, 0))
        #expect(isClose(snapshot.return1mPct, 0))
        #expect(isClose(snapshot.return3mPct, 0))
        #expect(isClose(snapshot.return6mPct, 0))
        #expect(isClose(snapshot.macdHistogramAsPercentOfClose, 0))
        #expect(isClose(snapshot.macdHistogramChangeOver5dPct, 0))
    }

    @Test func sortsUnorderedBarsAndCalculatesIndicators() throws {
        // close(i) = 100 + i for i in 0..<220 (last index 219 -> close 319)
        let bars = makeBars(
            close: { Double(100 + $0) },
            high: { $0 == 150 ? 400 : Double(100 + $0) }
        ).reversed()

        let snapshot = try MarketSnapshot(bars: Array(bars), ticker: "SPX")
        let last = 319.0
        // recentCloses has 200 items: indices 20...219 -> values 120...319
        #expect(snapshot.asOf == "2025-08-24")
        #expect(snapshot.latestClosingPrice == last)
        #expect(isClose(snapshot.priceIndexed, last / 120.0 * 100))

        // Mean of arithmetic progression a...b is (a + b) / 2
        let ma20 = (300.0 + 319.0) / 2
        let ma60 = (260.0 + 319.0) / 2
        let ma200 = (120.0 + 319.0) / 2
        let ma200Then = (100.0 + 299.0) / 2
        let ma20Then = (295.0 + 314.0) / 2

        #expect(isClose(snapshot.priceVsMa20Pct, (last / ma20 - 1) * 100))
        #expect(isClose(snapshot.priceVsMa60Pct, (last / ma60 - 1) * 100))
        #expect(isClose(snapshot.priceVsMa200Pct, (last / ma200 - 1) * 100))
        #expect(isClose(snapshot.ma200Slope20dPct, (ma200 / ma200Then - 1) * 100))
        #expect(isClose(snapshot.ma20Slope5dPct, (ma20 / ma20Then - 1) * 100))
        #expect(isClose(snapshot.drawdownFrom200dHighPct, (last / 400.0 - 1) * 100))

        #expect(isClose(snapshot.return1dPct, (last / (last - 1) - 1) * 100))
        #expect(isClose(snapshot.return1mPct, (last / (last - 21) - 1) * 100))
        #expect(isClose(snapshot.return3mPct, (last / (last - 63) - 1) * 100))
        #expect(isClose(snapshot.return6mPct, (last / (last - 126) - 1) * 100))
    }

    @Test func countsDaysSinceMa60Cross() throws {
        // Stay at 100, then drop to 80 for the last 4 trading days (3 days ago through today)
        let total = MarketSnapshot.requiredBarCount
        let bars = makeBars(close: { index in
            index >= total - 4 ? 80 : 100
        })
        let snapshot = try MarketSnapshot(bars: bars)
        #expect(snapshot.priceVsMa60Pct < 0)
        #expect(snapshot.tradingDaysSinceCloseCrossedMa60 == 3)
    }
}
