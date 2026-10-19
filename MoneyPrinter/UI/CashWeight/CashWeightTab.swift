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

    func reload(allMarkets: Bool = false) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let selected = market
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
        let targets = allMarkets
            ? [selected] + CashWeightMarket.allCases.filter { $0 != selected }
            : [selected]
        do {
            for target in targets {
                try await refresh(target, store: store)
                if target == selected, generation == reloadGeneration {
                    applyRecords(for: selected, store: store)
                }
            }
        } catch {
            if generation == reloadGeneration {
                errorMessage = error.localizedDescription
            }
        }
        guard generation == reloadGeneration else { return }
        applyRecords(for: selected, store: store)
    }

    private func refresh(_ target: CashWeightMarket, store: CashWeightStore) async throws {
        let snapshot = try await target.makeSnapshot()
        guard store.record(on: snapshot.asOf, ticker: target.ticker)?.samples.isEmpty ?? true else { return }
        let client = try JevClient.fromEnvironment()
        let previous = store.history(ticker: target.ticker).first { $0.day < snapshot.asOf }?.fraction ?? 1
        _ = try await CashWeight.ask(
            snapshot: snapshot,
            previousFraction: previous,
            client: client,
            question: target.question,
            store: store
        )
    }

    private func applyRecords(for target: CashWeightMarket, store: CashWeightStore) {
        let records = store.history(ticker: target.ticker)
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
            .toolbar { RefreshToolbarButton(isLoading: screen.isLoading) { await screen.reload() } }
            .dashboardScreen()
        }
        .task { await screen.reload(allMarkets: true) }
        .onChange(of: screen.market) {
            Task { await screen.reload() }
        }
    }

    private func recordList(_ today: CashWeightRecord) -> some View {
        @Bindable var screen = screen
        return List {
            AllocationHeroSection(title: screen.market.title, record: today)
            if screen.market == .kodexSP500 {
                orderSection(cashFraction: today.fraction, confidence: today.confidence)
            }
            SnapshotDisclosureSection(snapshot: today.snapshot)
            RawDetailDisclosureSection(record: today)
            if !screen.history.isEmpty {
                Section("최근 5일 판단") {
                    ForEach(screen.history.prefix(5)) { record in
                        NavigationLink {
                            CashWeightDetail(record: record)
                        } label: {
                            LabeledContent(record.day) {
                                Text("주식 \(DisplayNumber.fraction(1 - record.fraction)) · 현금 \(DisplayNumber.fraction(record.fraction))")
                                    .font(Theme.captionMetricFont)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.card)
            }
            ErrorSection(message: screen.errorMessage)
        }
        .dashboardList()
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
                    .foregroundStyle(orderNote.hasPrefix("주문번호") ? Theme.accent : Theme.danger)
            }
        } header: {
            Label(APIConfigManager.isDemo ? "모의 주문" : "실전 주문", systemImage: "wonsign.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(APIConfigManager.isDemo ? Theme.muted : Theme.accent)
        } footer: {
            Text("KODEX 미국S&P500(H)만, 평일 09:00–15:20에 시장가로 맞춥니다. 차이가 계좌의 10% 미만이면 주문하지 않고, 넘으면 목표 수량까지 한 번에 맞춥니다. confidence가 0.5 미만인 날은 주문하지 않습니다.")
        }
        .listRowBackground(Theme.card)
    }

    private func orderColor(_ action: RebalanceOrder.Action) -> Color {
        switch action {
        case .buy: Theme.positive
        case .sell: Theme.negative
        case .hold: Theme.foreground
        }
    }
}
