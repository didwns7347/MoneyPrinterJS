import SwiftUI

struct CashWeightDetail: View {
    let record: CashWeightRecord

    var body: some View {
        List {
            AllocationHeroSection(title: record.snapshot.ticker, record: record)
            SnapshotDisclosureSection(snapshot: record.snapshot)
            RawDetailDisclosureSection(record: record)
        }
        .dashboardList()
        .navigationTitle(record.day)
    }
}

struct AllocationHeroSection: View {
    let title: String
    let record: CashWeightRecord

    var body: some View {
        let stockFraction = 1 - record.fraction
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title)
                        .font(Theme.headlineFont)
                        .foregroundStyle(Theme.foreground)
                    Spacer()
                    Text("\(record.day) 종가 기준")
                        .font(Theme.captionMetricFont)
                        .foregroundStyle(Theme.muted)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("주식 목표")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                        Text(DisplayNumber.fraction(stockFraction))
                            .font(Theme.heroFont)
                            .foregroundStyle(Theme.foreground)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("현금 목표")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                        Text(DisplayNumber.fraction(record.fraction))
                            .font(Theme.heroFont)
                            .foregroundStyle(Theme.accent)
                    }
                }
                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        if stockFraction > 0 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.foreground.opacity(0.85))
                                .frame(width: max(6, proxy.size.width * stockFraction))
                        }
                        if record.fraction > 0 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.accent)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 8)
                HStack {
                    Text("Score \(DisplayNumber.decimal(record.score, digits: 2))")
                    Text("·")
                    Text("confidence \(DisplayNumber.decimal(record.confidence, digits: 2))")
                        .foregroundStyle(record.confidence < Rebalance.minConfidence ? Theme.danger : Theme.muted)
                    Spacer()
                    Text("\(record.samples.count)회 평균")
                }
                .font(Theme.captionMetricFont)
                .foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Theme.card)
    }
}

struct SnapshotDisclosureSection: View {
    let snapshot: MarketSnapshot

    var body: some View {
        Section {
            DisclosureGroup("판단에 쓴 지표") {
                if let return1d = snapshot.return1dPct {
                    MetricRow(title: "전일 대비", value: DisplayNumber.percent(return1d), tone: return1d)
                }
                MetricRow(
                    title: "200거래일 전 종가 = 100",
                    value: DisplayNumber.decimal(snapshot.priceIndexed, digits: 1),
                    tone: snapshot.priceIndexed - 100
                )
                MetricRow(title: "20거래일 이동평균 대비", value: DisplayNumber.percent(snapshot.priceVsMa20Pct), tone: snapshot.priceVsMa20Pct)
                MetricRow(title: "60거래일 이동평균 대비", value: DisplayNumber.percent(snapshot.priceVsMa60Pct), tone: snapshot.priceVsMa60Pct)
                MetricRow(title: "200거래일 이동평균 대비", value: DisplayNumber.percent(snapshot.priceVsMa200Pct), tone: snapshot.priceVsMa200Pct)
                MetricRow(title: "200거래일 이동평균 20일 변화", value: DisplayNumber.percent(snapshot.ma200Slope20dPct), tone: snapshot.ma200Slope20dPct)
                MetricRow(title: "200거래일 최고가 대비", value: DisplayNumber.percent(snapshot.drawdownFrom200dHighPct), tone: snapshot.drawdownFrom200dHighPct)
                if let histogram = snapshot.macdHistogramAsPercentOfClose {
                    MetricRow(title: "MACD 히스토그램", value: DisplayNumber.percent(histogram), tone: histogram)
                }
                if let change = snapshot.macdHistogramChangeOver5dPct {
                    MetricRow(title: "MACD 5거래일 변화", value: DisplayNumber.percent(change) + "p", tone: change)
                }
                MetricRow(title: "20일/60일 연율 변동성", value: "\(DisplayNumber.percent(snapshot.volatility20dPct)) / \(DisplayNumber.percent(snapshot.volatility60dPct))", tone: nil)
                MetricRow(title: "수익률 (1·3·6개월)", value: "\(DisplayNumber.percent(snapshot.return1mPct)) / \(DisplayNumber.percent(snapshot.return3mPct)) / \(DisplayNumber.percent(snapshot.return6mPct))", tone: snapshot.return3mPct)
            }
        }
        .listRowBackground(Theme.card)
    }
}

struct RawDetailDisclosureSection: View {
    let record: CashWeightRecord

    var body: some View {
        Section {
            DisclosureGroup("Jev 회차별 점수 및 원문 JSON") {
                ForEach(Array(record.samples.enumerated()), id: \.offset) { index, sample in
                    LabeledContent("\(index + 1)회차") {
                        Text("Score \(DisplayNumber.decimal(sample.score, digits: 2)) · confidence \(DisplayNumber.decimal(sample.confidence, digits: 2))")
                            .font(Theme.captionMetricFont)
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                }
                LabeledContent("모델") {
                    Text(record.model)
                        .font(Theme.captionMetricFont)
                }
                LabeledContent("입력 토큰") {
                    Text(DisplayNumber.decimal(Double(record.inputTokens), digits: 0))
                        .font(Theme.captionMetricFont)
                }
                JSONBlock(title: "요청 JSON", json: record.requestJSON)
                JSONBlock(title: "응답 JSON", json: record.responseJSON)
            }
        }
        .listRowBackground(Theme.card)
    }
}

private struct JSONBlock: View {
    let title: String
    let json: String

    var body: some View {
        if !json.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                Text(json)
                    .font(Theme.captionMetricFont)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        }
    }
}
