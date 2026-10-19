import Foundation

struct MarketSnapshot: Codable {
    /// 200일 이동평균의 20일 기울기를 계산하려면 최신 200일 앞에 20일이 더 필요합니다.
    static let lookback = 200
    static let slopeLag = 20
    static let requiredBarCount = lookback + slopeLag

    private(set) var ticker: String
    /// 마지막 일봉의 거래일. `yyyy-MM-dd`
    private(set) var asOf: String
    /// 마지막 일봉의 종가. 이 값을 저장하기 전의 기록에는 없습니다.
    private(set) var latestClosingPrice: Double?
    /// 최근 200거래일 첫 종가를 100으로 둔 현재 지수.
    let priceIndexed: Double
    /// 현재 종가가 20거래일 이동평균보다 높은 정도. 단위는 퍼센트 포인트입니다.
    let priceVsMa20Pct: Double
    let priceVsMa60Pct: Double
    let priceVsMa200Pct: Double
    /// 200거래일 이동평균이 20거래일 전 값보다 변한 정도. 단위는 퍼센트 포인트입니다.
    let ma200Slope20dPct: Double
    /// 최근 일간 수익률의 표본 표준편차를 1년(252거래일)으로 환산한 값. 단위는 퍼센트입니다.
    let volatility20dPct: Double
    let volatility60dPct: Double
    /// 최근 200거래일 최고가 대비 현재 종가. 0 이하면 그 최고가 아래입니다.
    let drawdownFrom200dHighPct: Double
    /// 직전 거래일 종가 대비 현재 종가 등락률. 단위는 퍼센트 포인트입니다. 이 값을 저장하기 전의 기록에는 없습니다.
    let return1dPct: Double?
    /// 21, 63, 126거래일 전 종가 대비 현재 종가. 단위는 퍼센트 포인트입니다.
    let return1mPct: Double
    let return3mPct: Double
    let return6mPct: Double
    /// 12거래일 지수이동평균에서 26거래일 지수이동평균을 뺀 값과, 그 차이의 9거래일 지수이동평균 사이 간격. 종가 대비 퍼센트입니다. 양수면 짧은 상승 속도가 아직 남아 있습니다.
    let macdHistogramAsPercentOfClose: Double?
    /// 지금 MACD 히스토그램에서 5거래일 전 값을 뺀 차이. 단위는 퍼센트 포인트입니다. 양수면 탄력이 살아나고 있습니다.
    let macdHistogramChangeOver5dPct: Double?
    /// 20거래일 이동평균이 5거래일 전 값보다 변한 정도. 단위는 퍼센트 포인트입니다.
    let ma20Slope5dPct: Double?
    /// 종가가 60거래일 이동평균을 마지막으로 넘거나 깬 뒤 지난 거래일 수. 교차가 없으면 확인한 거래일 수입니다.
    let tradingDaysSinceCloseCrossedMa60: Int?

    enum CodingKeys: String, CodingKey {
        case ticker = "index_symbol"
        case asOf = "last_trading_day"
        case latestClosingPrice = "latest_closing_price"
        case priceIndexed = "price_with_close_200_trading_days_ago_set_to_100"
        case priceVsMa20Pct = "percent_difference_from_20_trading_day_moving_average"
        case priceVsMa60Pct = "percent_difference_from_60_trading_day_moving_average"
        case priceVsMa200Pct = "percent_difference_from_200_trading_day_moving_average"
        case ma200Slope20dPct = "percent_change_of_200_trading_day_moving_average_over_prior_20_trading_days"
        case volatility20dPct = "annualized_percent_volatility_of_daily_returns_over_20_trading_days"
        case volatility60dPct = "annualized_percent_volatility_of_daily_returns_over_60_trading_days"
        case drawdownFrom200dHighPct = "percent_change_from_highest_high_of_last_200_trading_days"
        case return1dPct = "percent_return_over_prior_1_trading_day"
        case return1mPct = "percent_return_over_prior_21_trading_days"
        case return3mPct = "percent_return_over_prior_63_trading_days"
        case return6mPct = "percent_return_over_prior_126_trading_days"
        case macdHistogramAsPercentOfClose = "histogram_of_12_minus_26_trading_day_exponential_moving_average_as_percent_of_closing_price"
        case macdHistogramChangeOver5dPct = "change_over_prior_5_trading_days_of_histogram_of_12_minus_26_trading_day_exponential_moving_average_in_percentage_points"
        case ma20Slope5dPct = "percent_change_of_20_trading_day_moving_average_over_prior_5_trading_days"
        case tradingDaysSinceCloseCrossedMa60 = "trading_days_since_close_last_crossed_60_trading_day_moving_average"
    }

    init(bars: [IndexDailyBar], ticker: String = "SPX") throws {
        let ordered = bars.sorted { $0.date < $1.date }
        guard ordered.count >= Self.requiredBarCount else {
            throw MarketSnapshotError.insufficientHistory(have: ordered.count, need: Self.requiredBarCount)
        }
        let window = Array(ordered.suffix(Self.requiredBarCount))
        let closes = try window.map { bar -> Double in
            guard bar.close > 0, bar.high > 0 else {
                throw MarketSnapshotError.invalidPrice(date: bar.date)
            }
            return bar.close
        }
        let highs = window.map(\.high)
        let price = closes[closes.count - 1]
        let recentCloses = Array(closes.suffix(Self.lookback))
        let recentHighs = Array(highs.suffix(Self.lookback))

        self.ticker = ticker
        self.asOf = Self.isoDate(window[window.count - 1].date)
        self.latestClosingPrice = price
        self.priceIndexed = price / recentCloses[0] * 100
        self.priceVsMa20Pct = Self.gapPercent(price: price, average: Self.mean(closes, period: 20))
        self.priceVsMa60Pct = Self.gapPercent(price: price, average: Self.mean(closes, period: 60))
        let ma200 = Self.mean(closes, period: Self.lookback)
        self.priceVsMa200Pct = Self.gapPercent(price: price, average: ma200)
        let ma200Then = Self.mean(Array(closes.dropLast(Self.slopeLag)), period: Self.lookback)
        self.ma200Slope20dPct = Self.gapPercent(price: ma200, average: ma200Then)
        self.volatility20dPct = Self.annualizedVolatilityPercent(closes, period: 20)
        self.volatility60dPct = Self.annualizedVolatilityPercent(closes, period: 60)
        self.drawdownFrom200dHighPct = Self.gapPercent(price: price, average: recentHighs.max() ?? price)
        self.return1dPct = Self.gapPercent(price: price, average: closes[closes.count - 2])
        self.return1mPct = Self.gapPercent(price: price, average: closes[closes.count - 1 - 21])
        self.return3mPct = Self.gapPercent(price: price, average: closes[closes.count - 1 - 63])
        self.return6mPct = Self.gapPercent(price: price, average: closes[closes.count - 1 - 126])
        let histograms = Self.macdHistogramPercents(closes)
        self.macdHistogramAsPercentOfClose = histograms.last
        self.macdHistogramChangeOver5dPct = histograms.count > 5
            ? histograms[histograms.count - 1] - histograms[histograms.count - 6]
            : nil
        self.ma20Slope5dPct = Self.gapPercent(
            price: Self.mean(closes, period: 20),
            average: Self.mean(Array(closes.dropLast(5)), period: 20)
        )
        self.tradingDaysSinceCloseCrossedMa60 = Self.tradingDaysSinceCloseCrossedAverage(closes, period: 60)
    }

    /// 날짜, 종목, 절대 가격을 지운 사본. 백테스트에서 모델이 그 뒤 시장 흐름을 떠올리지 못하게 합니다.
    func masked() -> MarketSnapshot {
        var copy = self
        copy.ticker = ""
        copy.asOf = ""
        copy.latestClosingPrice = nil
        return copy
    }

    private static func mean(_ values: [Double], period: Int) -> Double {
        let slice = values.suffix(period)
        return slice.reduce(0, +) / Double(period)
    }

    private static func gapPercent(price: Double, average: Double) -> Double {
        (price / average - 1) * 100
    }

    private static func annualizedVolatilityPercent(_ closes: [Double], period: Int) -> Double {
        let slice = Array(closes.suffix(period + 1))
        let returns = zip(slice, slice.dropFirst()).map { yesterday, today in
            today / yesterday - 1
        }
        let count = Double(returns.count)
        let mean = returns.reduce(0, +) / count
        let variance = returns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (count - 1)
        return variance.squareRoot() * (252 as Double).squareRoot() * 100
    }

    /// 12, 26, 9 거래일. 각 지수이동평균은 첫 구간의 단순평균에서 시작합니다. 마지막 값이 오늘이고, 각 값은 그날 종가 대비 퍼센트입니다.
    private static func macdHistogramPercents(_ closes: [Double]) -> [Double] {
        let fast = exponentialMovingAverage(closes, period: 12)
        let slow = exponentialMovingAverage(closes, period: 26)
        let macd = zip(fast.suffix(slow.count), slow).map { $0 - $1 }
        let signal = exponentialMovingAverage(macd, period: 9)
        return zip(zip(macd.suffix(signal.count), signal), closes.suffix(signal.count)).map { pair, close in
            (pair.0 - pair.1) / close * 100
        }
    }

    private static func tradingDaysSinceCloseCrossedAverage(_ closes: [Double], period: Int) -> Int {
        func isAbove(_ index: Int) -> Bool {
            let average = closes[(index - period + 1) ... index].reduce(0, +) / Double(period)
            return closes[index] >= average
        }
        let last = closes.count - 1
        let side = isAbove(last)
        var index = last
        while index - 1 >= period - 1, isAbove(index - 1) == side {
            index -= 1
        }
        return last - index
    }

    private static func exponentialMovingAverage(_ values: [Double], period: Int) -> [Double] {
        guard values.count >= period, period > 0 else { return [] }
        var average = values.prefix(period).reduce(0, +) / Double(period)
        var averages = [average]
        let weight = 2 / Double(period + 1)
        for value in values.dropFirst(period) {
            average = (value - average) * weight + average
            averages.append(average)
        }
        return averages
    }

    static func isoDate(_ yyyymmdd: String) -> String {
        guard yyyymmdd.count == 8 else { return yyyymmdd }
        let year = yyyymmdd.prefix(4)
        let month = yyyymmdd.dropFirst(4).prefix(2)
        let day = yyyymmdd.suffix(2)
        return "\(year)-\(month)-\(day)"
    }
}

enum MarketSnapshotError: LocalizedError {
    case insufficientHistory(have: Int, need: Int)
    case invalidPrice(date: String)

    var errorDescription: String? {
        switch self {
        case .insufficientHistory(let have, let need):
            return "일봉이 \(have)개입니다. 지표 계산에는 \(need)개가 필요합니다."
        case .invalidPrice(let date):
            return "\(date) 종가 또는 고가가 없습니다."
        }
    }
}

extension KoreaInvestmentAPIService {
    /// KODEX 200. 코스피200을 따르는 ETF입니다.
    static let kodex200 = "069500"
    /// KODEX 미국S&P500(H). 코스피에 상장된 미국 S&P500 환헤지 ETF입니다.
    static let kodexUSSP500H = "449180"

    func makeSPXSnapshot() async throws -> MarketSnapshot {
        let bars = try await fetchSPXDailyBars(tradingDays: MarketSnapshot.requiredBarCount)
        return try MarketSnapshot(bars: bars)
    }

    /// 정규장은 15:30에 끝납니다. 일봉 종가가 반영될 여유를 두고 이 시각부터 오늘 일봉을 확정된 것으로 봅니다. 서울 기준입니다.
    static let closedBarHour = 15
    static let closedBarMinute = 40

    /// `closedOnly`가 참이면, 아직 장이 끝나지 않은 오늘 일봉을 빼고 직전 거래일 종가까지로 계산합니다.
    func makeKODEX200Snapshot(closedOnly: Bool = false) async throws -> MarketSnapshot {
        try await makeDomesticETFSnapshot(stockCode: Self.kodex200, closedOnly: closedOnly)
    }

    func makeKODEXUSSP500HSnapshot(closedOnly: Bool = false) async throws -> MarketSnapshot {
        try await makeDomesticETFSnapshot(stockCode: Self.kodexUSSP500H, closedOnly: closedOnly)
    }

    private func makeDomesticETFSnapshot(stockCode: String, closedOnly: Bool) async throws -> MarketSnapshot {
        let bars = closedOnly
            ? try await fetchClosedDomesticBars(stockCode: stockCode, tradingDays: MarketSnapshot.requiredBarCount)
            : try await fetchDomesticDailyBars(stockCode: stockCode, tradingDays: MarketSnapshot.requiredBarCount)
        return try MarketSnapshot(bars: bars, ticker: stockCode)
    }

    /// 아직 장이 끝나지 않은 오늘 일봉을 빼고, 종가가 확정된 일봉만 `tradingDays`개 돌려줍니다.
    func fetchClosedDomesticBars(stockCode: String, tradingDays: Int) async throws -> [IndexDailyBar] {
        var bars = try await fetchDomesticDailyBars(stockCode: stockCode, tradingDays: tradingDays + 1)
        if let open = Self.openSessionDay(), bars.last?.date == open {
            bars.removeLast()
        }
        return Array(bars.suffix(tradingDays))
    }

    /// 오늘 일봉이 아직 확정되지 않았으면 오늘 날짜(`yyyyMMdd`)를 돌려줍니다.
    private static func openSessionDay(now: Date = Date()) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard minutes < closedBarHour * 60 + closedBarMinute else { return nil }
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
