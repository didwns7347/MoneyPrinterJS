import Foundation

enum CashWeightMarket: String, CaseIterable, Identifiable {
    case kodexSP500
    case kodex200

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .kodexSP500: "KODEX SNP500(H)"
        case .kodex200: "KODEX 200"
        }
    }

    var ticker: String {
        switch self {
        case .kodexSP500: KoreaInvestmentAPIService.kodexUSSP500H
        case .kodex200: KoreaInvestmentAPIService.kodex200
        }
    }

    var question: String {
        """
        Determine the appropriate cash allocation for a portfolio invested in the \(instrumentName).

        Use only the supplied MarketSnapshot derived from daily prices. Do not use external data, fundamentals, news, or macroeconomic assumptions.

        The portfolio is reviewed daily and has a long-term investment horizon. The objective is to participate in sustained market advances while reducing exposure during persistent downtrends and elevated market risk. Do not try to catch the exact bottom or the exact top.

        All percent fields are in percent units, so 5.0 means 5%.

        Assess three areas separately, then combine them.

        1. Long-term trend. This area has the highest priority.
        - Core signals: price relative to the 200-trading-day moving average, and the percent change of that average over the prior 20 trading days.
        - Close above a rising 200-day average is a long-term uptrend. Close below a falling 200-day average is a long-term downtrend. Anything else is an unclear trend.
        - Price relative to the 60- and 20-trading-day moving averages is supporting evidence only.

        2. Momentum. Is the move strengthening or weakening?
        - Returns over the prior 21, 63, and 126 trading days. Note when shorter and longer returns disagree.
        - The 12/26/9 MACD histogram as a percent of the close, and its change over the prior 5 trading days. A positive change means momentum is strengthening, a negative change means it is fading.
        - Percent change of the 20-trading-day moving average over the prior 5 trading days.
        - Trading days since the close last crossed the 60-trading-day moving average. This count has no direction by itself; read it together with the sign of the price relative to the 60-day average. If no cross occurred in the available history, the value is the number of trading days checked.

        3. Risk. Should stock exposure be reduced?
        - Annualized volatility over 20 and 60 trading days. A 20-day value well above the 60-day value means risk is rising quickly.
        - Change from the highest high of the last 200 trading days. This shows the size of the decline, not its future direction.
        - Return over the prior 1 trading day, to spot a one-day shock.
        - Do not cut exposure on a single risk signal. Lower exposure when risk is confirmed by several indicators at once.

        Combine the areas with these rules:
        - Strong long-term uptrend, positive momentum, and low risk allows the lowest cash allocation.
        - In a long-term uptrend with fading short-term momentum, hold back from raising the ETF allocation.
        - A long-term downtrend with negative momentum calls for a higher cash allocation.
        - A volatility spike together with a large drawdown caps the ETF allocation.
        - When areas conflict, choose a middle allocation, not an extreme.

        Do not treat a high absolute price as evidence of overvaluation. Do not treat a recent decline alone as evidence that the market is cheap or that a rebound is imminent. Avoid counting correlated indicators as independent evidence.

        Select the criterion whose market state best matches the combined assessment.
        """
    }

    private var instrumentName: String {
        switch self {
        case .kodexSP500: "KODEX U.S. S&P 500 currency-hedged ETF"
        case .kodex200: "KODEX 200 ETF"
        }
    }

    /// 정규장 종가가 정해진 일봉만 씁니다.
    func makeSnapshot() async throws -> MarketSnapshot {
        switch self {
        case .kodexSP500:
            try await KoreaInvestmentAPIService.shared.makeKODEXUSSP500HSnapshot(closedOnly: true)
        case .kodex200:
            try await KoreaInvestmentAPIService.shared.makeKODEX200Snapshot(closedOnly: true)
        }
    }
}

/// Jev Score로 정한 현금 비중. 0은 전액 주식, 1은 전액 현금입니다.
struct CashWeight {
    static let questionID = "cash_weight"
    /// 같은 스냅샷으로 물어 평균을 내는 횟수.
    static let sampleCount = 3

    static let criteria = [
        "0% cash. Strong long-term uptrend, positive and strengthening momentum, low risk.",
        "25% cash. Uptrend dominates. Momentum is positive or only mildly fading, and risk is moderate at most.",
        "50% cash. Mixed or uncertain. Trend, momentum, and risk point in different directions.",
        "75% cash. Downtrend dominates, or risk is rising across several indicators.",
        "100% cash. Strong long-term downtrend, negative momentum, very high risk.",
    ]

    let fraction: Double
    let score: Double
    let confidence: Double
    /// confidence가 문턱 미만이라 어제 비중을 유지했습니다.
    let heldPrevious: Bool

    static func ask(
        snapshot: MarketSnapshot,
        previousFraction: Double,
        client: JevClient,
        question: String,
        store: CashWeightStore? = nil
    ) async throws -> CashWeight {
        let store = store ?? CashWeightStore.shared
        var samples: [CashWeightSample] = []
        var model = ""
        var requestJSON = ""
        var responseJSONs: [String] = []
        for _ in 0 ..< sampleCount {
            let result = try await sample(state: snapshot, client: client, question: question)
            samples.append(result.sample)
            model = result.model
            requestJSON = result.requestJSON
            responseJSONs.append(result.responseJSON)
        }
        let count = Double(samples.count)
        let weight = resolve(
            score: samples.map(\.score).reduce(0, +) / count,
            confidence: samples.map(\.confidence).reduce(0, +) / count
        )
        try store.save(
            CashWeightRecord(
                day: snapshot.asOf,
                calledAt: Date(),
                model: model,
                inputTokens: samples.map(\.inputTokens).reduce(0, +),
                snapshot: snapshot,
                fraction: weight.fraction,
                score: weight.score,
                confidence: weight.confidence,
                heldPrevious: weight.heldPrevious,
                previousFraction: previousFraction,
                requestJSON: requestJSON,
                responseJSON: "[\n" + responseJSONs.joined(separator: ",\n") + "\n]",
                samples: samples
            )
        )
        return weight
    }

    /// Jev에 한 번 묻습니다. 저장하지 않습니다.
    static func sample<State: Encodable>(
        state: State,
        client: JevClient,
        question: String
    ) async throws -> (sample: CashWeightSample, model: String, requestJSON: String, responseJSON: String) {
        let (response, request, responseJSON) = try await client.systemOneRaw(
            state: state,
            questions: [
                questionID: .score(question, criteria: criteria),
            ]
        )
        guard let answer = response.answers[questionID],
              let score = answer.score,
              let confidence = answer.confidence
        else {
            throw CashWeightError.missingScore
        }
        let sample = CashWeightSample(score: score, confidence: confidence, inputTokens: response.usage.inputTokens)
        return (sample, response.model, request, responseJSON)
    }

    static func resolve(score: Double, confidence: Double) -> CashWeight {
        let upper = Double(criteria.count - 1)
        let fraction = clamp(score / upper)
        return CashWeight(fraction: fraction, score: score, confidence: confidence, heldPrevious: false)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

enum CashWeightError: LocalizedError {
    case missingScore
    case failedToSave(String)

    var errorDescription: String? {
        switch self {
        case .missingScore:
            return "Jev 응답에 현금 비중 Score가 없습니다."
        case .failedToSave(let message):
            return "현금 비중 기록을 저장하지 못했습니다: \(message)"
        }
    }
}
