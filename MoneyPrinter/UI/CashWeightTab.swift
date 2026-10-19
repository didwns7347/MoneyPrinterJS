import SwiftUI

@MainActor
@Observable
private final class CashWeightScreen {
    var market: CashWeightMarket = .kodexSP500
    private(set) var today: CashWeightRecord?
    private(set) var history: [CashWeightRecord] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var orderPlan: RebalanceOrder?
    private(set) var orderNote: String?
    private(set) var isOrdering = false
    var confirmingOrder = false
    private var reloadGeneration = 0

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let market = market
        isLoading = true
        errorMessage = nil
        orderPlan = nil
        orderNote = nil
        defer {
            if generation == reloadGeneration {
                isLoading = false
            }
        }

        let store = CashWeightStore.shared
        do {
            let snapshot = try await market.makeSnapshot()
            if store.record(on: snapshot.asOf, ticker: market.ticker)?.samples.isEmpty ?? true {
                let client = try JevClient.fromEnvironment()
                let previous = store.history(ticker: market.ticker).first { $0.day < snapshot.asOf }?.fraction ?? 1
                _ = try await CashWeight.ask(
                    snapshot: snapshot,
                    previousFraction: previous,
                    client: client,
                    question: market.question,
                    store: store
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        guard generation == reloadGeneration else { return }
        let records = store.history(ticker: market.ticker)
        today = records.first
        history = Array(records.dropFirst())
    }

    func previewOrder(cashFraction: Double, confidence: Double) async {
        guard market == .kodexSP500 else { return }
        isOrdering = true
        orderNote = nil
        defer { isOrdering = false }
        do {
            let api = KoreaInvestmentAPIService.shared
            let ticker = market.ticker
            async let balance = api.fetchDomesticStockBalance()
            async let price = api.domesticLastPrice(stockCode: ticker)
            let response = try await balance
            let holding = response.stockList?.first { $0.code == ticker }
            orderPlan = Rebalance.order(
                cashFraction: cashFraction,
                confidence: confidence,
                cash: Rebalance.integer(response.accountSummary?.first?.orderableCash),
                held: Rebalance.integer(holding?.quantity),
                price: try await price
            )
        } catch {
            orderNote = error.localizedDescription
        }
    }

    func sendOrder() async {
        guard market == .kodexSP500, let plan = orderPlan else { return }
        guard Rebalance.marketIsOpen() else {
            orderNote = "정규장이 아니라 주문을 보내지 않았습니다."
            return
        }
        let side: DomesticOrderSide
        let quantity: Int
        switch plan.action {
        case .buy(let count):
            side = .buy
            quantity = count
        case .sell(let count):
            side = .sell
            quantity = count
        case .hold:
            return
        }
        isOrdering = true
        orderNote = nil
        defer { isOrdering = false }
        do {
            let receipt = try await KoreaInvestmentAPIService.shared.orderDomesticCash(
                side: side,
                ticker: market.ticker,
                quantity: quantity
            )
            orderNote = "주문번호 \(receipt.orderNumber)"
            orderPlan = nil
        } catch {
            orderNote = error.localizedDescription
        }
    }
}

struct CashWeightTab: View {
    @State private var screen = CashWeightScreen()

    var body: some View {
        @Bindable var screen = screen
        NavigationStack {
            VStack(spacing: 0) {
                Picker("지표", selection: $screen.market) {
                    ForEach(CashWeightMarket.allCases) { market in
                        Text(market.title).tag(market)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.vertical, 8)
                Group {
                    if let today = screen.today {
                        recordList(today)
                    } else if screen.isLoading {
                        ProgressView("\(screen.market.title) 현금 비중을 \(CashWeight.sampleCount)번 판단하는 중")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView {
                            Label("비중 판단이 없습니다", systemImage: "chart.pie")
                        } description: {
                            Text(screen.errorMessage ?? "오늘 판단을 불러오지 못했습니다.")
                        } actions: {
                            Button("다시 시도") {
                                Task { await screen.reload() }
                            }
                        }
                    }
                }
            }
            .navigationTitle("비중")
            .toolbar { refreshButton }
        }
        .task { await screen.reload() }
        .onChange(of: screen.market) {
            Task { await screen.reload() }
        }
    }

    private func recordList(_ today: CashWeightRecord) -> some View {
        @Bindable var screen = screen
        return List {
            if screen.market == .kodexSP500 {
                orderSection(cashFraction: today.fraction, confidence: today.confidence)
            }
            Section {
                LabeledContent("지표", value: screen.market.title)
                LabeledContent("종가 기준일", value: today.day)
                LabeledContent("현금", value: percent(today.fraction))
                LabeledContent("주식", value: percent(1 - today.fraction))
                LabeledContent("Score", value: DisplayNumber.decimal(today.score, digits: 2))
                LabeledContent("confidence", value: DisplayNumber.decimal(today.confidence, digits: 2))
                SampleRows(samples: today.samples)
                if today.heldPrevious {
                    Text("confidence가 0.5 미만이라 어제 현금 비중 \(percent(today.previousFraction))을 유지했습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("모델", value: today.model)
                LabeledContent("입력 토큰", value: DisplayNumber.decimal(Double(today.inputTokens), digits: 0))
            } header: {
                Text("최근 판단")
            } footer: {
                Text("거래일마다 한 번, 장 마감 뒤 확정된 종가로 \(CashWeight.sampleCount)번 물어 평균을 냅니다. 장중에는 직전 거래일 판단을 보여 줍니다.")
            }
            JSONSection(title: "요청 JSON", json: today.requestJSON)
            JSONSection(title: "응답 JSON", json: today.responseJSON)
            snapshotSections(today.snapshot)
            if !screen.history.isEmpty {
                Section("이전 판단") {
                    ForEach(screen.history) { record in
                        NavigationLink {
                            CashWeightDetail(record: record)
                        } label: {
                            LabeledContent(record.day, value: "현금 \(percent(record.fraction))")
                        }
                    }
                }
            }
            if let errorMessage = screen.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .refreshable { await screen.reload() }
        .alert(orderAlertTitle, isPresented: $screen.confirmingOrder) {
            Button("주문", role: .destructive) {
                Task { await screen.sendOrder() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(screen.orderPlan?.summary ?? "")
        }
    }

    private var orderAlertTitle: String {
        APIConfigManager.isDemo ? "모의투자 주문을 보낼까요?" : "실전 주문을 보낼까요?"
    }

    private func orderSection(cashFraction: Double, confidence: Double) -> some View {
        Section {
            if let plan = screen.orderPlan {
                HStack {
                    Text(plan.summary)
                        .font(.headline)
                        .foregroundStyle(orderColor(plan.action))
                    Spacer()
                    Button("다시 비교") {
                        Task { await screen.previewOrder(cashFraction: cashFraction, confidence: confidence) }
                    }
                    .font(.subheadline)
                    .disabled(screen.isOrdering)
                }
                LabeledContent("보유 → 목표", value: "\(plan.held)주 → \(plan.targetQuantity)주")
                    .monospacedDigit()
                LabeledContent("현재가", value: DisplayNumber.won(String(plan.price)))
                    .monospacedDigit()
                LabeledContent("예수금", value: DisplayNumber.won(String(plan.cash)))
                    .monospacedDigit()
                if plan.sendsOrder, Rebalance.marketIsOpen() {
                    Button {
                        screen.confirmingOrder = true
                    } label: {
                        Text("\(plan.summary) 주문 보내기")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(orderColor(plan.action))
                    .controlSize(.large)
                    .disabled(screen.isOrdering)
                } else if plan.sendsOrder {
                    Label("정규장(평일 09:00–15:20)에만 주문할 수 있습니다.", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await screen.previewOrder(cashFraction: cashFraction, confidence: confidence) }
                } label: {
                    Label("계좌 잔고와 비교해 주문 수량 계산", systemImage: "arrow.left.arrow.right.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(screen.isOrdering)
            }
            if screen.isOrdering {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            if let orderNote = screen.orderNote {
                Text(orderNote)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(orderNote.hasPrefix("주문번호") ? Color.primary : Color.red)
            }
        } header: {
            Label(APIConfigManager.isDemo ? "모의 주문" : "실전 주문", systemImage: "wonsign.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(APIConfigManager.isDemo ? Color.secondary : Color.red)
        } footer: {
            Text("KODEX 미국S&P500(H)만, 평일 09:00–15:20에 시장가로 맞춥니다. 차이가 계좌의 10% 미만이면 주문하지 않고, 넘으면 목표 수량까지 한 번에 맞춥니다. confidence가 0.5 미만인 날은 주문하지 않습니다.")
        }
    }

    private func orderColor(_ action: RebalanceOrder.Action) -> Color {
        switch action {
        case .buy: .red
        case .sell: .blue
        case .hold: .primary
        }
    }

    @ViewBuilder
    private func snapshotSections(_ snapshot: MarketSnapshot) -> some View {
        Section("판단에 쓴 지표") {
            LabeledContent("기준일", value: snapshot.asOf)
            LabeledContent("종목", value: snapshot.ticker)
            MetricRow(
                title: "200거래일 전 종가 = 100",
                value: DisplayNumber.decimal(snapshot.priceIndexed, digits: 1),
                tone: snapshot.priceIndexed - 100
            )
        }
        Section("추세") {
            MetricRow(title: "20거래일 이동평균 대비", value: DisplayNumber.percent(snapshot.priceVsMa20Pct), tone: snapshot.priceVsMa20Pct)
            MetricRow(title: "60거래일 이동평균 대비", value: DisplayNumber.percent(snapshot.priceVsMa60Pct), tone: snapshot.priceVsMa60Pct)
            MetricRow(title: "200거래일 이동평균 대비", value: DisplayNumber.percent(snapshot.priceVsMa200Pct), tone: snapshot.priceVsMa200Pct)
            MetricRow(title: "200거래일 이동평균의 20거래일 변화", value: DisplayNumber.percent(snapshot.ma200Slope20dPct), tone: snapshot.ma200Slope20dPct)
            MetricRow(title: "200거래일 최고가 대비", value: DisplayNumber.percent(snapshot.drawdownFrom200dHighPct), tone: snapshot.drawdownFrom200dHighPct)
        }
        Section("연율 변동성") {
            MetricRow(title: "20거래일 일간 수익률", value: DisplayNumber.percent(snapshot.volatility20dPct), tone: nil)
            MetricRow(title: "60거래일 일간 수익률", value: DisplayNumber.percent(snapshot.volatility60dPct), tone: nil)
        }
        MomentumSection(snapshot: snapshot)
        Section("수익률") {
            MetricRow(title: "21거래일", value: DisplayNumber.percent(snapshot.return1mPct), tone: snapshot.return1mPct)
            MetricRow(title: "63거래일", value: DisplayNumber.percent(snapshot.return3mPct), tone: snapshot.return3mPct)
            MetricRow(title: "126거래일", value: DisplayNumber.percent(snapshot.return6mPct), tone: snapshot.return6mPct)
        }
    }

    private var refreshButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("새로고침", systemImage: "arrow.clockwise") {
                Task { await screen.reload() }
            }
            .disabled(screen.isLoading)
        }
    }

    private func percent(_ fraction: Double) -> String {
        DisplayNumber.decimal(fraction * 100, digits: 1) + "%"
    }
}

private struct SampleRows: View {
    let samples: [CashWeightSample]

    var body: some View {
        ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
            LabeledContent("\(index + 1)회차") {
                Text("Score \(DisplayNumber.decimal(sample.score, digits: 2)) · confidence \(DisplayNumber.decimal(sample.confidence, digits: 2))")
                    .monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

private struct JSONSection: View {
    let title: String
    let json: String

    var body: some View {
        Section(title) {
            if json.isEmpty {
                Text("이 기록은 \(title)을 저장하기 전에 만들었습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}

struct CashWeightDetail: View {
    let record: CashWeightRecord

    var body: some View {
        List {
            Section(record.day) {
                LabeledContent("현금", value: DisplayNumber.decimal(record.fraction * 100, digits: 1) + "%")
                LabeledContent("주식", value: DisplayNumber.decimal((1 - record.fraction) * 100, digits: 1) + "%")
                LabeledContent("Score", value: DisplayNumber.decimal(record.score, digits: 2))
                LabeledContent("confidence", value: DisplayNumber.decimal(record.confidence, digits: 2))
                SampleRows(samples: record.samples)
                LabeledContent("모델", value: record.model)
            }
            JSONSection(title: "요청 JSON", json: record.requestJSON)
            JSONSection(title: "응답 JSON", json: record.responseJSON)
            Section("판단에 쓴 지표") {
                LabeledContent("기준일", value: record.snapshot.asOf)
                MetricRow(
                    title: "200거래일 전 종가 = 100",
                    value: DisplayNumber.decimal(record.snapshot.priceIndexed, digits: 1),
                    tone: record.snapshot.priceIndexed - 100
                )
                MetricRow(title: "20거래일 이동평균 대비", value: DisplayNumber.percent(record.snapshot.priceVsMa20Pct), tone: record.snapshot.priceVsMa20Pct)
                MetricRow(title: "60거래일 이동평균 대비", value: DisplayNumber.percent(record.snapshot.priceVsMa60Pct), tone: record.snapshot.priceVsMa60Pct)
                MetricRow(title: "200거래일 이동평균 대비", value: DisplayNumber.percent(record.snapshot.priceVsMa200Pct), tone: record.snapshot.priceVsMa200Pct)
                MetricRow(title: "200거래일 이동평균의 20거래일 변화", value: DisplayNumber.percent(record.snapshot.ma200Slope20dPct), tone: record.snapshot.ma200Slope20dPct)
                MetricRow(title: "200거래일 최고가 대비", value: DisplayNumber.percent(record.snapshot.drawdownFrom200dHighPct), tone: record.snapshot.drawdownFrom200dHighPct)
                MetricRow(title: "20거래일 연율 변동성", value: DisplayNumber.percent(record.snapshot.volatility20dPct), tone: nil)
                MetricRow(title: "60거래일 연율 변동성", value: DisplayNumber.percent(record.snapshot.volatility60dPct), tone: nil)
                MetricRow(title: "21거래일", value: DisplayNumber.percent(record.snapshot.return1mPct), tone: record.snapshot.return1mPct)
                MetricRow(title: "63거래일", value: DisplayNumber.percent(record.snapshot.return3mPct), tone: record.snapshot.return3mPct)
                MetricRow(title: "126거래일", value: DisplayNumber.percent(record.snapshot.return6mPct), tone: record.snapshot.return6mPct)
            }
            MomentumSection(snapshot: record.snapshot)
        }
        .navigationTitle(record.day)
    }
}
