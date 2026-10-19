import SwiftUI

@MainActor
@Observable
private final class SnapshotStore {
    private(set) var snapshot: MarketSnapshot?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            snapshot = try await KoreaInvestmentAPIService.shared.makeKODEXUSSP500HSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SnapshotTab: View {
    @State private var store = SnapshotStore()

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = store.snapshot {
                    snapshotList(snapshot)
                } else if store.isLoading {
                    ProgressView("KODEX 미국S&P500(H) 지표를 계산하는 중")
                } else {
                    ContentUnavailableView {
                        Label("오늘 지표가 없습니다", systemImage: "chart.xyaxis.line")
                    } description: {
                        Text(store.errorMessage ?? "지표를 불러오지 못했습니다.")
                    } actions: {
                        Button("다시 시도") {
                            Task { await store.reload() }
                        }
                    }
                }
            }
            .navigationTitle("오늘")
            .toolbar { RefreshToolbarButton(isLoading: store.isLoading) { await store.reload() } }
            .dashboardScreen()
        }
        .task { await store.reload() }
    }

    private func snapshotList(_ snapshot: MarketSnapshot) -> some View {
        List {
            heroSection(snapshot)
            Section {
                MetricRow(
                    title: "20거래일 이동평균 대비",
                    subtitle: "단기(약 1개월) 평균선과의 괴리 · 단기 과열·침체 확인",
                    value: DisplayNumber.percent(snapshot.priceVsMa20Pct),
                    tone: snapshot.priceVsMa20Pct
                )
                MetricRow(
                    title: "60거래일 이동평균 대비",
                    subtitle: "중기(약 3개월) 수급선과의 괴리 · 추세 전환 핵심 기준",
                    value: DisplayNumber.percent(snapshot.priceVsMa60Pct),
                    tone: snapshot.priceVsMa60Pct
                )
                MetricRow(
                    title: "200거래일 이동평균 대비",
                    subtitle: "장기(약 1년) 추세선과의 괴리 · 강세·약세장 구분",
                    value: DisplayNumber.percent(snapshot.priceVsMa200Pct),
                    tone: snapshot.priceVsMa200Pct
                )
                MetricRow(
                    title: "200거래일 이동평균 20일 기울기",
                    subtitle: "장기 추세선 자체가 최근 한 달간 오르는지 꺾이는지 확인",
                    value: DisplayNumber.percent(snapshot.ma200Slope20dPct),
                    tone: snapshot.ma200Slope20dPct
                )
                MetricRow(
                    title: "200거래일 최고가 대비 (낙폭)",
                    subtitle: "최근 1년 고점 대비 하락 폭 · 0%에 가까울수록 신고가 부근",
                    value: DisplayNumber.percent(snapshot.drawdownFrom200dHighPct),
                    tone: snapshot.drawdownFrom200dHighPct
                )
            } header: {
                Text("추세 · 위치")
            } footer: {
                Text("현재 가격이 단·중·장기 이동평균선 위에서 순항 중인지, 고점 대비 얼마나 조정받았는지 보여 줍니다.")
            }
            MomentumSection(snapshot: snapshot)
            Section {
                MetricRow(
                    title: "21거래일 수익률 (약 1개월)",
                    subtitle: "단기 누적 등락 흐름",
                    value: DisplayNumber.percent(snapshot.return1mPct),
                    tone: snapshot.return1mPct
                )
                MetricRow(
                    title: "63거래일 수익률 (약 3개월)",
                    subtitle: "중기(분기) 누적 등락 흐름",
                    value: DisplayNumber.percent(snapshot.return3mPct),
                    tone: snapshot.return3mPct
                )
                MetricRow(
                    title: "126거래일 수익률 (약 6개월)",
                    subtitle: "장기(반기) 누적 등락 흐름",
                    value: DisplayNumber.percent(snapshot.return6mPct),
                    tone: snapshot.return6mPct
                )
            } header: {
                Text("기간별 수익률")
            }
            Section {
                MetricRow(
                    title: "20거래일 연율 변동성",
                    subtitle: "최근 1개월 일간 수익률 흔들림을 1년(252일) 기준으로 환산",
                    value: DisplayNumber.percent(snapshot.volatility20dPct),
                    tone: nil
                )
                MetricRow(
                    title: "60거래일 연율 변동성",
                    subtitle: "최근 3개월 평균 변동성 · 20일 변동성이 더 크면 단기 불안 확대",
                    value: DisplayNumber.percent(snapshot.volatility60dPct),
                    tone: nil
                )
            } header: {
                Text("변동성 · 위험도")
            } footer: {
                Text("변동성이 급등하는 구간에서는 추세가 꺾일 때 현금 비중을 높여 방어합니다.")
            }
            ErrorSection(message: store.errorMessage)
        }
        .dashboardList()
        .refreshable { await store.reload() }
    }

    private func heroSection(_ snapshot: MarketSnapshot) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("KODEX 미국S&P500(H)")
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.foreground)
                    Text(snapshot.ticker)
                        .font(Theme.captionMetricFont)
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(snapshot.asOf) 기준")
                        .font(Theme.captionMetricFont)
                        .foregroundStyle(Theme.muted)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("현재가 · 전일 대비")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let price = snapshot.latestClosingPrice {
                                Text(DisplayNumber.decimal(price, digits: 0) + "원")
                                    .font(Theme.heroFont)
                                    .foregroundStyle(Theme.foreground)
                            }
                            if let return1d = snapshot.return1dPct {
                                Text(DisplayNumber.percent(return1d))
                                    .font(Theme.metricFont)
                                    .foregroundStyle(QuoteTone.color(return1d))
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("200거래일 전 = 100")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                        Text(DisplayNumber.decimal(snapshot.priceIndexed, digits: 1))
                            .font(Theme.heroFont)
                            .foregroundStyle(QuoteTone.color(snapshot.priceIndexed - 100))
                    }
                }
                Text("최근 220거래일 일봉에서 추출한 기술적 지표입니다. Jev는 종목명·뉴스 없이 아래 숫자만으로 현금 비중을 판단합니다.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Theme.card)
    }
}

private struct MomentumSection: View {
    let snapshot: MarketSnapshot

    var body: some View {
        if snapshot.macdHistogramAsPercentOfClose != nil || snapshot.ma20Slope5dPct != nil {
            Section {
                if let histogram = snapshot.macdHistogramAsPercentOfClose {
                    MetricRow(
                        title: "MACD 히스토그램",
                        subtitle: "12·26일 지수이평 차이와 9일 시그널 간격 · 양수면 단기 상승 우위",
                        value: DisplayNumber.percent(histogram),
                        tone: histogram
                    )
                }
                if let change = snapshot.macdHistogramChangeOver5dPct {
                    MetricRow(
                        title: "MACD 히스토그램 5거래일 변화",
                        subtitle: "최근 1주일간 상승 탄력이 강해지는지(+) 식는지(-) 확인",
                        value: DisplayNumber.percent(change) + "p",
                        tone: change
                    )
                }
                if let slope = snapshot.ma20Slope5dPct {
                    MetricRow(
                        title: "20거래일 이동평균 5거래일 기울기",
                        subtitle: "단기 평균선이 최근 1주일간 고개를 드는지 확인",
                        value: DisplayNumber.percent(slope),
                        tone: slope
                    )
                }
                if let days = snapshot.tradingDaysSinceCloseCrossedMa60 {
                    MetricRow(
                        title: "60거래일 이동평균 \(snapshot.priceVsMa60Pct >= 0 ? "위" : "아래") 유지",
                        subtitle: "중기 추세선 돌파/이탈 후 방향이 이어진 거래일 수",
                        value: "\(days)거래일째",
                        tone: snapshot.priceVsMa60Pct
                    )
                }
            } header: {
                Text("탄력 · 모멘텀")
            } footer: {
                Text("하락 후 반등이 확인되는 시점과 고점 근처에서 상승 힘이 빠지는 시점을 포착할 때 씁니다.")
            }
        }
    }
}
