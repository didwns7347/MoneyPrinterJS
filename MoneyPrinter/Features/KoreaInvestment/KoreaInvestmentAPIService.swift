import Foundation

class KoreaInvestmentAPIService {
    static let shared = KoreaInvestmentAPIService()
    private var tokenManager: TokenManager?
    private var http: HTTPClient?
    private let secureStorage: StorageProtocol

    private init(
        http: HTTPClient? = nil,
        secureStorage: StorageProtocol = KeychainStorage.shared
    ) {
        self.http = http
        self.secureStorage = secureStorage
        if let http {
            tokenManager = TokenManager(http: http, secureStorage: secureStorage)
        }
    }

    private func prepare() throws {
        if http != nil, tokenManager != nil { return }
        let config = try APIConfigManager.load()
        guard let baseURL = URL(string: config.baseURL) else {
            throw APIConfigError.invalidBaseURL(config.baseURL)
        }
        let client = HTTPClient(baseURL: baseURL)
        http = client
        tokenManager = TokenManager(http: client, secureStorage: secureStorage)
    }

    private func validToken() async throws -> String {
        try prepare()
        guard let tokenManager else { throw APIConfigError.missingKeys(["APP_KEY"]) }
        return try await tokenManager.getValidToken()
    }

    private func request<T: Decodable>(
        _ endpoint: KoreaInvestmentEndpoint,
        retry: RetryPolicy? = nil
    ) async throws -> T {
        try prepare()
        guard let http else { throw APIConfigError.missingKeys(["URL_BASE"]) }
        return try await http.send(endpoint.makeRequest(), as: T.self, retryPolicy: retry)
    }

    func resetToken() async throws {
        try prepare()
        await tokenManager?.resetToken()
    }

    /// 국내주식 일별 주가 데이터를 가져옵니다.
    func fetchDomesticDailyPrice(stockCode: String, period: String = "D") async throws -> [DailyPriceInfo] {
        let token = try await validToken()
        let (start, fin) = getStartFinDates()
        let endpoint = KoreaInvestmentEndpoint.fetchDailyPrice(
            token: token,
            stockCode: stockCode,
            periodDivCode: period,
            startDate: start,
            finDate: fin
        )
        let response: StockPriceResponse = try await request(endpoint)

        guard response.returnCode == "0" else {
            throw NSError(domain: "KoreaInvestmentAPI", code: Int(response.returnCode) ?? -1, userInfo: [NSLocalizedDescriptionKey: response.message])
        }

        return response.dailyPrices
    }

    /// S&P500 지수(SPX) 일봉을 오래된 날짜부터 반환합니다.
    /// 기간별시세는 한 번에 약 100건이라, 필요한 거래일 수만큼 구간을 나눠 호출합니다.
    func fetchSPXDailyBars(tradingDays: Int) async throws -> [IndexDailyBar] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        var end = Date()
        var collected: [String: IndexDailyBar] = [:]

        for _ in 0..<8 {
            guard collected.count < tradingDays,
                  let start = calendar.date(byAdding: .day, value: -120, to: end) else { break }
            let candles = try await fetchOverseasIndexCandles(
                symbol: "SPX",
                startDate: Self.ymd(start, calendar: calendar),
                endDate: Self.ymd(end, calendar: calendar)
            )
            let countBefore = collected.count
            for candle in candles {
                guard let close = Double(candle.close), close > 0,
                      let high = Double(candle.high), high > 0
                else {
                    throw MarketSnapshotError.invalidPrice(date: candle.date)
                }
                collected[candle.date] = IndexDailyBar(date: candle.date, close: close, high: max(high, close))
            }
            guard collected.count > countBefore,
                  let oldest = candles.map(\.date).min(),
                  let oldestDate = Self.date(from: oldest, calendar: calendar),
                  let nextEnd = calendar.date(byAdding: .day, value: -1, to: oldestDate) else { break }
            end = nextEnd
        }

        let ordered = collected.values.sorted { $0.date < $1.date }
        guard ordered.count >= tradingDays else {
            throw MarketSnapshotError.insufficientHistory(have: ordered.count, need: tradingDays)
        }
        return Array(ordered.suffix(tradingDays))
    }

    /// 코스피 상장 ETF 일봉을 오래된 날짜부터 반환합니다. 수정주가를 사용합니다.
    /// 국내 기간별시세는 한 번에 약 100건이라, 필요한 거래일 수만큼 구간을 나눠 호출합니다.
    func fetchDomesticDailyBars(stockCode: String, tradingDays: Int) async throws -> [IndexDailyBar] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        var end = Date()
        var collected: [String: IndexDailyBar] = [:]

        for _ in 0..<8 {
            guard collected.count < tradingDays,
                  let start = calendar.date(byAdding: .day, value: -120, to: end) else { break }
            let candles = try await fetchDomesticChart(
                stockCode: stockCode,
                startDate: Self.ymd(start, calendar: calendar),
                endDate: Self.ymd(end, calendar: calendar)
            )
            let countBefore = collected.count
            for candle in candles {
                guard let close = Self.number(candle.closingPrice), close > 0,
                      let high = Self.number(candle.highPrice), high > 0
                else {
                    throw MarketSnapshotError.invalidPrice(date: candle.businessDate)
                }
                collected[candle.businessDate] = IndexDailyBar(
                    date: candle.businessDate,
                    close: close,
                    high: max(high, close)
                )
            }
            guard collected.count > countBefore,
                  let oldest = candles.map(\.businessDate).min(),
                  let oldestDate = Self.date(from: oldest, calendar: calendar),
                  let nextEnd = calendar.date(byAdding: .day, value: -1, to: oldestDate) else { break }
            end = nextEnd
        }

        let ordered = collected.values.sorted { $0.date < $1.date }
        guard ordered.count >= tradingDays else {
            throw MarketSnapshotError.insufficientHistory(have: ordered.count, need: tradingDays)
        }
        return Array(ordered.suffix(tradingDays))
    }

    private func fetchDomesticChart(
        stockCode: String,
        startDate: String,
        endDate: String
    ) async throws -> [DailyPriceInfo] {
        let token = try await validToken()
        let endpoint = KoreaInvestmentEndpoint.fetchDailyPrice(
            token: token,
            stockCode: stockCode,
            periodDivCode: "D",
            startDate: startDate,
            finDate: endDate
        )
        let response: StockPriceResponse = try await request(endpoint)
        guard response.returnCode == "0" else {
            throw NSError(
                domain: "KoreaInvestmentAPI",
                code: Int(response.returnCode) ?? -1,
                userInfo: [NSLocalizedDescriptionKey: response.message]
            )
        }
        return response.dailyPrices
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }

    private func fetchOverseasIndexCandles(
        symbol: String,
        startDate: String,
        endDate: String
    ) async throws -> [OverseasIndexCandle] {
        let token = try await validToken()
        let endpoint = KoreaInvestmentEndpoint.fetchOverseasIndexDailyPrice(
            token: token,
            symbol: symbol,
            startDate: startDate,
            endDate: endDate
        )
        let response: OverseasIndexChartResponse = try await request(endpoint)
        guard response.returnCode == "0" else {
            throw NSError(
                domain: "KoreaInvestmentAPI",
                code: Int(response.returnCode) ?? -1,
                userInfo: [NSLocalizedDescriptionKey: response.message]
            )
        }
        return response.candles
    }

    private static func ymd(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func date(from yyyymmdd: String, calendar: Calendar) -> Date? {
        guard yyyymmdd.count == 8,
              let year = Int(yyyymmdd.prefix(4)),
              let month = Int(yyyymmdd.dropFirst(4).prefix(2)),
              let day = Int(yyyymmdd.suffix(2)) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// 해외주식 일별 주가 데이터를 가져옵니다.
    func fetchOverseasDailyPrice(stockCode: String, excd: ExchangeCode = .NAS) async throws -> [OverseasDailyStockPrice] {
        let token = try await validToken()
        let endpoint = KoreaInvestmentEndpoint.fetchOverseasDailyPrice(token: token, EXCD: excd.rawValue, SYMB: stockCode)
        let response: OverseasStockPriceInfo = try await request(endpoint)

        guard response.returnCode == "0" else {
            throw NSError(domain: "KoreaInvestmentAPI", code: Int(response.returnCode) ?? -1, userInfo: [NSLocalizedDescriptionKey: response.message])
        }
        return response.priceHistories
    }

    /// 국내주식 잔고를 조회합니다.
    func fetchDomesticStockBalance() async throws -> DomesticStockBalanceResponse {
        let token = try await validToken()
        let endpoint = KoreaInvestmentEndpoint.fetchDomesticStockBalance(
            token: token
        )
        let response: DomesticStockBalanceResponse = try await request(endpoint)

        guard response.isSuccess else {
            let errorMessage = "[\(response.messageCode)] \(response.message)"
            throw NSError(
                domain: "KoreaInvestmentAPI",
                code: Int(response.returnCode) ?? -1,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
        }

        return response
    }

    /// 국내주식 영업 실적 조회
    func fetchDomesticStockPerformance(code: String) async throws -> DomesticStockPerformanceResponse {
        let token = try await validToken()
        let endpoint = KoreaInvestmentEndpoint.fetchDomesticStockPerformance(token: token, stockCode: code)
        return try await request(endpoint)
    }

    /// 국내주식 기본 조회
    func fetchDomesticStockDetail(code: String) async throws -> DomesticStockDetail {
        let token = try await validToken()
        let endpoint = KoreaInvestmentEndpoint.fetchDomesticStockInfo(token: token, stockCode: code)
        let response: DomesticStockDetailResponse = try await request(endpoint)
        return response.output
    }

    /// 해외주식 잔고를 조회합니다.
    func fetchOverseasStockBalance(
        exchangeCode: String = "NASD",
        currencyCode: String = "USD"
    ) async throws -> OverseasStockBalanceResponse {
        let token = try await validToken()
        let endpoint = KoreaInvestmentEndpoint.fetchOverseasStockBalance(
            token: token,
            OVRS_EXCG_CD: exchangeCode,
            TR_CRCY_CD: currencyCode
        )
        let response: OverseasStockBalanceResponse = try await request(endpoint)

        guard response.isSuccess else {
            let errorMessage = "[\(response.messageCode)] \(response.message)"
            throw NSError(
                domain: "KoreaInvestmentAPI",
                code: Int(response.returnCode) ?? -1,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
        }

        return response
    }

    /// 해외주식 예수금 조회
    func fetchOverseasAccountBalance() async throws -> OverseasAccountBalance {
        let token = try await validToken()
        let endpoint = KoreaInvestmentEndpoint.fetchOverseasAccountBalance(token: token, OVRS_EXCG_CD: "NASD")
        let response: OverseasAccountInfo = try await request(endpoint)
        guard response.isSuccess else {
            let errorMessage = "[\(response.messageCode)] \(response.message)"
            throw NSError(
                domain: "KoreaInvestmentAPI",
                code: Int(response.returnCode) ?? -1,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
        }
        return response.balance
    }

    /// 국내 현금 시장가 주문. 같은 본문으로 hashkey를 받은 뒤 한 번만 보냅니다.
    func orderDomesticCash(side: DomesticOrderSide, ticker: String, quantity: Int) async throws -> DomesticCashOrderReceipt {
        guard quantity > 0 else { throw OrderError.invalidQuantity }
        let token = try await validToken()
        let config = try APIConfigManager.load()
        var fields = [
            "ACNT_PRDT_CD": config.accountCode,
            "CANO": config.cano,
            "EXCG_ID_DVSN_CD": "KRX",
            "ORD_DVSN": "01",
            "ORD_QTY": String(quantity),
            "ORD_UNPR": "0",
            "PDNO": ticker,
        ]
        if side == .sell {
            fields["SLL_TYPE"] = "01"
        }
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let hash: HashKeyResponse = try await request(.hashKey(body: body), retry: RetryPolicy.none)
        let response: DomesticCashOrderResponse = try await request(
            .orderCash(token: token, side: side, body: body, hash: hash.hash),
            retry: RetryPolicy.none
        )
        guard response.isSuccess, let output = response.output else {
            throw OrderError.rejected(response.message)
        }
        return DomesticCashOrderReceipt(orderNumber: output.orderNumber, orderTime: output.orderTime)
    }

    func domesticLastPrice(stockCode: String) async throws -> Int {
        let token = try await validToken()
        let response: DomesticLastPriceResponse = try await request(
            .fetchDomesticStockInfo(token: token, stockCode: stockCode)
        )
        let price = Rebalance.integer(response.output.price)
        guard price > 0 else { throw OrderError.rejected("현재가가 없습니다.") }
        return price
    }

    /// 3달치
    private func getStartFinDates() -> (String, String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let start = Calendar.current.date(byAdding: .month, value: -3, to: Date())
        return (start.map { formatter.string(from: $0) } ?? "", formatter.string(from: Date()))
    }
}

private struct DomesticLastPriceResponse: Decodable {
    let output: Output

    struct Output: Decodable {
        let price: String

        enum CodingKeys: String, CodingKey {
            case price = "stck_prpr"
        }
    }
}
