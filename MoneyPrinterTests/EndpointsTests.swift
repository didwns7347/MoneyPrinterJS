import Foundation
import Testing
@testable import MoneyPrinter

struct EndpointsTests {
    @Test func issueToken() {
        let endpoint = KoreaInvestmentEndpoint.issueToken
        #expect(endpoint.method == .post)
        #expect(endpoint.path == "/oauth2/tokenP")
    }

    @Test func domesticDailyPrice() {
        let endpoint = KoreaInvestmentEndpoint.fetchDailyPrice(
            token: "t",
            stockCode: "005930",
            periodDivCode: "D",
            startDate: "20260101",
            finDate: "20260401"
        )
        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/uapi/domestic-stock/v1/quotations/inquire-daily-itemchartprice")
        #expect(endpoint.transactionID == "FHKST03010100")
        #expect(endpoint.query.contains(URLQueryItem(name: "fid_input_iscd", value: "005930")))
        #expect(endpoint.query.contains(URLQueryItem(name: "fid_period_div_code", value: "D")))
    }

    @Test func overseasDailyPrice() {
        let endpoint = KoreaInvestmentEndpoint.fetchOverseasDailyPrice(token: "t", EXCD: "NAS", SYMB: "AAPL")
        #expect(endpoint.path == "/uapi/overseas-price/v1/quotations/dailyprice")
        #expect(endpoint.transactionID == "HHDFS76240000")
        #expect(endpoint.query.contains(URLQueryItem(name: "GUBN", value: "0")))
    }

    @Test func overseasIndexDailyPrice() {
        let endpoint = KoreaInvestmentEndpoint.fetchOverseasIndexDailyPrice(
            token: "t",
            symbol: "SPX",
            startDate: "20260101",
            endDate: "20260401"
        )
        #expect(endpoint.path == "/uapi/overseas-price/v1/quotations/inquire-daily-chartprice")
        #expect(endpoint.transactionID == "FHKST03030100")
        #expect(endpoint.query.contains(URLQueryItem(name: "FID_INPUT_ISCD", value: "SPX")))
        #expect(endpoint.query.contains(URLQueryItem(name: "FID_COND_MRKT_DIV_CODE", value: "N")))
    }

    @Test func orderCash() {
        let buy = KoreaInvestmentEndpoint.orderCash(token: "t", side: .buy, body: Data(), hash: "h")
        #expect(buy.method == .post)
        #expect(buy.path == "/uapi/domestic-stock/v1/trading/order-cash")
        #expect(buy.transactionID == (APIConfigManager.isDemo ? "VTTC0802U" : "TTTC0802U"))
        let sell = KoreaInvestmentEndpoint.orderCash(token: "t", side: .sell, body: Data(), hash: "h")
        #expect(sell.transactionID == (APIConfigManager.isDemo ? "VTTC0801U" : "TTTC0801U"))
    }

    @Test func hashKey() {
        let endpoint = KoreaInvestmentEndpoint.hashKey(body: Data("{}".utf8))
        #expect(endpoint.method == .post)
        #expect(endpoint.path == "/uapi/hashkey")
        #expect(endpoint.transactionID == nil)
    }
}
