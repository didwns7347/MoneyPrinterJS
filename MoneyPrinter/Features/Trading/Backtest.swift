import Foundation

/// 하루치 Jev 판단. 이것만 있으면 Jev를 다시 부르지 않고 규칙만 바꿔 다시 시뮬레이션할 수 있습니다.
struct BacktestDecision: Codable {
    let score: Double
    let confidence: Double
    /// 판단에 쓴 마지막 종가의 거래일. `yyyy-MM-dd`
    var decisionDay = ""
    var model = ""
    var inputTokens = 0
    var responseJSON = ""
}

struct BacktestDay: Identifiable, Codable {
    /// 주문을 체결한 거래일. `yyyy-MM-dd`
    let day: String
    let price: Int
    let decision: BacktestDecision
    let cashFraction: Double
    let action: RebalanceOrder.Action
    let equity: Int
    let buyHoldEquity: Int

    var id: String { day }
    var confidence: Double { decision.confidence }

    var traded: Bool {
        if case .hold = action { return false }
        return true
    }
}

struct BacktestSummary {
    let returnPct: Double
    let buyHoldReturnPct: Double
    let maxDrawdownPct: Double
    let buyHoldMaxDrawdownPct: Double
    let tradeCount: Int
    let averageCashFraction: Double

    init?(days: [BacktestDay], startingCash: Int) {
        guard let last = days.last, startingCash > 0 else { return nil }
        let start = Double(startingCash)
        returnPct = (Double(last.equity) / start - 1) * 100
        buyHoldReturnPct = (Double(last.buyHoldEquity) / start - 1) * 100
        maxDrawdownPct = Self.maxDrawdown(days.map(\.equity), start: startingCash)
        buyHoldMaxDrawdownPct = Self.maxDrawdown(days.map(\.buyHoldEquity), start: startingCash)
        tradeCount = days.filter(\.traded).count
        averageCashFraction = days.map(\.cashFraction).reduce(0, +) / Double(days.count)
    }

    /// 고점 대비 가장 크게 빠진 비율. 0 이하입니다.
    private static func maxDrawdown(_ values: [Int], start: Int) -> Double {
        var peak = start
        var worst = 0.0
        for value in values {
            peak = max(peak, value)
            worst = min(worst, (Double(value) / Double(peak) - 1) * 100)
        }
        return worst
    }
}

enum Backtest {
    static let tradingDays = 100
    static let startingCash = 10_000_000

    /// 거래일마다 그날 종가까지의 일봉으로 판단하고, 다음 거래일 종가에 `Rebalance.order`대로 체결합니다.
    /// 처음에는 전액 현금이고, 수수료와 세금은 넣지 않습니다.
    /// `bars`는 `MarketSnapshot.requiredBarCount + tradingDays`개여야 판단이 `tradingDays`번 나옵니다.
    static func simulate(
        bars: [IndexDailyBar],
        startingCash: Int = startingCash,
        decide: (MarketSnapshot) async throws -> BacktestDecision,
        onDay: (BacktestDay) -> Void = { _ in }
    ) async throws -> [BacktestDay] {
        let ordered = bars.sorted { $0.date < $1.date }
        guard ordered.count > MarketSnapshot.requiredBarCount else {
            throw MarketSnapshotError.insufficientHistory(have: ordered.count, need: MarketSnapshot.requiredBarCount + 1)
        }
        var cash = startingCash
        var held = 0
        var buyHold: (shares: Int, cash: Int)?
        var days: [BacktestDay] = []

        for decisionIndex in (MarketSnapshot.requiredBarCount - 1) ..< (ordered.count - 1) {
            try Task.checkCancellation()
            let snapshot = try MarketSnapshot(bars: Array(ordered[...decisionIndex]))
            var decision = try await decide(snapshot)
            decision.decisionDay = snapshot.asOf
            let weight = CashWeight.resolve(score: decision.score, confidence: decision.confidence)
            let next = ordered[decisionIndex + 1]
            let price = Int(next.close.rounded())

            let order = Rebalance.order(
                cashFraction: weight.fraction,
                confidence: weight.confidence,
                cash: cash,
                held: held,
                price: price
            )
            switch order.action {
            case .buy(let quantity):
                cash -= quantity * price
                held += quantity
            case .sell(let quantity):
                cash += quantity * price
                held -= quantity
            case .hold:
                break
            }

            let benchmark = buyHold ?? (startingCash / max(price, 1), startingCash % max(price, 1))
            buyHold = benchmark
            let day = BacktestDay(
                day: MarketSnapshot.isoDate(next.date),
                price: price,
                decision: decision,
                cashFraction: weight.fraction,
                action: order.action,
                equity: cash + held * price,
                buyHoldEquity: benchmark.cash + benchmark.shares * price
            )
            days.append(day)
            onDay(day)
        }
        return days
    }

    /// 날짜, 종목, 절대 가격을 가린 스냅샷으로 Jev에 한 번 묻습니다. 실제 판단 기록에는 저장하지 않습니다.
    static func askJev(_ snapshot: MarketSnapshot, client: JevClient, question: String) async throws -> BacktestDecision {
        let result = try await CashWeight.sample(state: snapshot.masked(), client: client, question: question)
        return BacktestDecision(
            score: result.sample.score,
            confidence: result.sample.confidence,
            model: result.model,
            inputTokens: result.sample.inputTokens,
            responseJSON: result.responseJSON
        )
    }
}

/// 종목마다 마지막 백테스트 한 번을 남깁니다. 중간에 멈춰도 거기까지는 남습니다.
struct BacktestRun: Codable {
    let ticker: String
    let ranAt: Date
    let startingCash: Int
    var days: [BacktestDay]
}

enum BacktestStore {
    static func load(ticker: String) -> BacktestRun? {
        guard let data = try? Data(contentsOf: fileURL(ticker: ticker)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BacktestRun.self, from: data)
    }

    static func save(_ run: BacktestRun) throws {
        let url = fileURL(ticker: run.ticker)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: url, options: .atomic)
    }

    private static func fileURL(ticker: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoneyPrinter", isDirectory: true)
            .appendingPathComponent("backtest-\(ticker).json")
    }
}
