import Charts
import SwiftUI

@MainActor
@Observable
private final class BacktestScreen {
    var market: CashWeightMarket = .kodexSP500 {
        didSet {
            guard market != oldValue else { return }
            stop()
            errorMessage = nil
            loadSaved()
        }
    }
    private(set) var days: [BacktestDay] = []
    private(set) var ranAt: Date?
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    var confirming = false
    private var task: Task<Void, Never>?

    init() {
        loadSaved()
    }

    var summary: BacktestSummary? {
        BacktestSummary(days: days, startingCash: Backtest.startingCash)
    }

    func run() {
        task?.cancel()
        let market = market
        task = Task {
            isRunning = true
            errorMessage = nil
            days = []
            defer { isRunning = false }
            do {
                let client = try JevClient.fromEnvironment()
                let bars = try await KoreaInvestmentAPIService.shared.fetchClosedDomesticBars(
                    stockCode: market.ticker,
                    tradingDays: MarketSnapshot.requiredBarCount + Backtest.tradingDays
                )
                var run = BacktestRun(ticker: market.ticker, ranAt: Date(), startingCash: Backtest.startingCash, days: [])
                ranAt = run.ranAt
                _ = try await Backtest.simulate(bars: bars) { snapshot in
                    try await Backtest.askJev(snapshot, client: client, question: market.question)
                } onDay: { day in
                    self.days.append(day)
                    run.days.append(day)
                    do {
                        try BacktestStore.save(run)
                    } catch {
                        self.errorMessage = "백테스트 결과를 저장하지 못했습니다: \(error.localizedDescription)"
                    }
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    private func loadSaved() {
        let saved = BacktestStore.load(ticker: market.ticker)
        days = saved?.days ?? []
        ranAt = saved?.ranAt
    }
}

struct BacktestView: View {
    @State private var screen = BacktestScreen()

    var body: some View {
        @Bindable var screen = screen
        List {
            controlSection
            if let summary = screen.summary {
                summarySection(summary)
                chartSection
                tradesSection
            }
            ErrorSection(message: screen.errorMessage)
        }
        .dashboardList()
        .navigationTitle("백테스트")
        .alert("Jev를 \(Backtest.tradingDays)번 호출합니다", isPresented: $screen.confirming) {
            Button("실행") { screen.run() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("최근 \(Backtest.tradingDays)거래일을 하루씩 판단합니다. 몇 분 걸리고 호출 비용이 듭니다.")
        }
        .onDisappear { screen.stop() }
    }

    private var controlSection: some View {
        @Bindable var screen = screen
        return Section {
            Picker("종목", selection: $screen.market) {
                ForEach(CashWeightMarket.allCases) { market in
                    Text(market.title).tag(market)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(screen.isRunning)
            if screen.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(screen.days.count), total: Double(Backtest.tradingDays))
                        .tint(Theme.accent)
                    HStack {
                        Text("\(screen.days.count) / \(Backtest.tradingDays)거래일")
                            .font(Theme.captionMetricFont)
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Button("중지", role: .destructive) { screen.stop() }
                    }
                }
            } else {
                Button {
                    screen.confirming = true
                } label: {
                    Label(screen.days.isEmpty ? "최근 \(Backtest.tradingDays)거래일 백테스트" : "다시 실행", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        } header: {
            Text(screen.market.title)
        } footer: {
            Text("시작 1,000만원 전액 현금. 거래일마다 그날 종가까지의 지표로 Jev에 한 번 묻고, 다음 거래일 종가에 실제와 같은 규칙(차이 10% 이상, confidence 0.5 이상)으로 체결합니다. Jev가 그 뒤 시장을 떠올리지 못하게 날짜·종목·가격은 가리고 보냅니다. 수수료와 세금은 빠져 있습니다.")
        }
        .listRowBackground(Theme.card)
    }

    private func summarySection(_ summary: BacktestSummary) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("전략")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    Text(DisplayNumber.percent(summary.returnPct))
                        .font(Theme.heroFont)
                        .foregroundStyle(QuoteTone.color(summary.returnPct))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("그냥 보유")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    Text(DisplayNumber.percent(summary.buyHoldReturnPct))
                        .font(Theme.heroFont)
                        .foregroundStyle(QuoteTone.color(summary.buyHoldReturnPct))
                }
            }
            .padding(.vertical, 4)
            MetricRow(
                title: "최대 낙폭",
                subtitle: "고점 대비 가장 크게 빠진 폭 · 전략 / 그냥 보유",
                value: "\(DisplayNumber.percent(summary.maxDrawdownPct)) / \(DisplayNumber.percent(summary.buyHoldMaxDrawdownPct))",
                tone: nil
            )
            MetricRow(title: "매매 횟수", value: "\(summary.tradeCount)번", tone: nil)
            MetricRow(title: "평균 현금 비중", value: DisplayNumber.fraction(summary.averageCashFraction), tone: nil)
            NavigationLink {
                BacktestDecisionList(days: screen.days)
            } label: {
                MetricRow(
                    title: "Jev 판단 \(screen.days.count)개",
                    subtitle: "날짜별 Score · confidence · 응답 원문",
                    value: "",
                    tone: nil
                )
            }
        } header: {
            Text(screen.days.first.map { "\($0.day) ~ \(screen.days.last?.day ?? "")" } ?? "결과")
        } footer: {
            if let ranAt = screen.ranAt, !screen.isRunning {
                let partial = screen.days.count < Backtest.tradingDays ? " · 중간에 멈춘 결과" : ""
                Text("\(ranAt.formatted(date: .abbreviated, time: .shortened)) 실행 결과 저장됨\(partial)")
            }
        }
        .listRowBackground(Theme.card)
    }

    private var chartSection: some View {
        Section("평가금액") {
            Chart {
                ForEach(Array(screen.days.enumerated()), id: \.offset) { index, day in
                    LineMark(x: .value("거래일", index), y: .value("원", day.buyHoldEquity))
                        .foregroundStyle(by: .value("구분", "그냥 보유"))
                    LineMark(x: .value("거래일", index), y: .value("원", day.equity))
                        .foregroundStyle(by: .value("구분", "전략"))
                }
            }
            .chartForegroundStyleScale(["전략": Theme.accent, "그냥 보유": Theme.muted])
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis(.hidden)
            .frame(height: 220)
        }
        .listRowBackground(Theme.card)
    }

    private var tradesSection: some View {
        Section("매매한 날") {
            let trades = screen.days.filter(\.traded)
            if trades.isEmpty {
                Text("주문 조건을 넘은 날이 없습니다.")
                    .foregroundStyle(Theme.muted)
            }
            ForEach(trades) { day in
                LabeledContent {
                    Text(Self.actionText(day.action))
                        .font(Theme.metricFont)
                        .foregroundStyle(Self.actionColor(day.action))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.day)
                            .font(Theme.captionMetricFont)
                        Text("현금 목표 \(DisplayNumber.fraction(day.cashFraction)) · \(DisplayNumber.decimal(Double(day.price), digits: 0))원")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .listRowBackground(Theme.card)
    }

    private static func actionText(_ action: RebalanceOrder.Action) -> String {
        switch action {
        case .buy(let quantity): "\(quantity)주 매수"
        case .sell(let quantity): "\(quantity)주 매도"
        case .hold: "유지"
        }
    }

    private static func actionColor(_ action: RebalanceOrder.Action) -> Color {
        switch action {
        case .buy: Theme.positive
        case .sell: Theme.negative
        case .hold: Theme.foreground
        }
    }
}

private struct BacktestDecisionList: View {
    let days: [BacktestDay]

    var body: some View {
        List(days) { day in
            DisclosureGroup {
                LabeledContent("판단 기준일", value: day.decision.decisionDay)
                LabeledContent("체결일", value: day.day)
                LabeledContent("모델", value: day.decision.model)
                LabeledContent("입력 토큰", value: "\(day.decision.inputTokens)")
                if !day.decision.responseJSON.isEmpty {
                    Text(day.decision.responseJSON)
                        .font(Theme.captionMetricFont)
                        .textSelection(.enabled)
                }
            } label: {
                LabeledContent {
                    Text("현금 \(DisplayNumber.fraction(day.cashFraction))")
                        .font(Theme.metricFont)
                        .foregroundStyle(Theme.accent)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.decision.decisionDay)
                            .font(Theme.captionMetricFont)
                        Text("Score \(DisplayNumber.decimal(day.decision.score, digits: 2)) · confidence \(DisplayNumber.decimal(day.confidence, digits: 2))")
                            .font(.caption)
                            .foregroundStyle(day.confidence < Rebalance.minConfidence ? Theme.danger : Theme.muted)
                    }
                }
            }
            .listRowBackground(Theme.card)
        }
        .dashboardList()
        .navigationTitle("Jev 판단")
    }
}
