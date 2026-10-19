//
//  HistoryTab.swift
//  MoneyPrinter
//
//  Created by yangjs on 10/15/26.
//

import Charts
import SwiftUI

@MainActor
@Observable
private final class CashWeightHistory {
    var market: CashWeightMarket = .kodexSP500
    private(set) var kospiRecords: [CashWeightRecord] = []
    private(set) var snpRecords: [CashWeightRecord] = []

    /// 최근 판단이 앞에 옵니다.
    var records: [CashWeightRecord] {
        switch market {
        case .kodexSP500: snpRecords
        case .kodex200: kospiRecords
        }
    }

    func load() {
        let store = CashWeightStore.shared
        kospiRecords = store.history(ticker: CashWeightMarket.kodex200.ticker)
        snpRecords = store.history(ticker: CashWeightMarket.kodexSP500.ticker)
    }
}

struct HistoryTab: View {
    @State private var screen = CashWeightHistory()

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
                if screen.records.isEmpty {
                    ContentUnavailableView {
                        Label("쌓인 판단이 없습니다", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("비중 탭에서 판단을 받으면 날짜별로 여기에 남습니다.")
                    }
                } else {
                    recordList(screen.records)
                }
            }
            .navigationTitle("기록")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        BacktestView()
                    } label: {
                        Label("백테스트", systemImage: "clock.arrow.2.circlepath")
                    }
                }
            }
            .dashboardScreen()
        }
        .onAppear { screen.load() }
    }

    private func recordList(_ records: [CashWeightRecord]) -> some View {
        List {
            Section("현금 비중 추이") {
                CashWeightChart(records: Array(records.reversed()))
                    .frame(height: 200)
            }
            .listRowBackground(Theme.card)
            Section("요약") {
                LabeledContent("판단 수") {
                    Text("\(records.count)일")
                        .font(Theme.metricFont)
                }
                LabeledContent("평균 현금") {
                    Text(DisplayNumber.fraction(records.map(\.fraction).reduce(0, +) / Double(records.count)))
                        .font(Theme.metricFont)
                        .foregroundStyle(Theme.accent)
                }
                if let first = records.last, let last = records.first {
                    LabeledContent("기간") {
                        Text("\(first.day) ~ \(last.day)")
                            .font(Theme.captionMetricFont)
                    }
                }
            }
            .listRowBackground(Theme.card)
            Section("날짜별 판단") {
                ForEach(records) { record in
                    NavigationLink {
                        CashWeightDetail(record: record)
                    } label: {
                        HistoryRow(record: record)
                    }
                }
            }
            .listRowBackground(Theme.card)
        }
        .dashboardList()
        .refreshable { screen.load() }
    }
}

private struct CashWeightChart: View {
    let records: [CashWeightRecord]

    var body: some View {
        Chart(records) { record in
            AreaMark(
                x: .value("날짜", record.day),
                y: .value("현금", record.fraction * 100)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Theme.accent.opacity(0.25), Theme.accent.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            LineMark(
                x: .value("날짜", record.day),
                y: .value("현금", record.fraction * 100)
            )
            .foregroundStyle(Theme.accent)
            PointMark(
                x: .value("날짜", record.day),
                y: .value("현금", record.fraction * 100)
            )
            .foregroundStyle(Theme.accent)
        }
        .chartYScale(domain: 0 ... 100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Int.self) {
                        Text("\(number)%")
                            .font(Theme.captionMetricFont)
                    }
                }
            }
        }
        .chartXAxis(.hidden)
    }
}

private struct HistoryRow: View {
    let record: CashWeightRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.day)
                    .font(Theme.headlineFont)
                    .foregroundStyle(Theme.foreground)
                Spacer()
                Text("현금 \(DisplayNumber.fraction(record.fraction))")
                    .font(Theme.metricFont)
                    .foregroundStyle(Theme.accent)
                    .monospacedDigit()
            }
            HStack {
                Text("Score \(DisplayNumber.decimal(record.score, digits: 2))")
                Text("confidence \(DisplayNumber.decimal(record.confidence, digits: 2))")
                Spacer()
                if let histogram = record.snapshot.macdHistogramAsPercentOfClose {
                    Text("MACD \(DisplayNumber.percent(histogram))")
                        .foregroundStyle(QuoteTone.color(histogram))
                }
            }
            .font(Theme.captionMetricFont)
            .foregroundStyle(Theme.muted)
            .monospacedDigit()
        }
    }
}
