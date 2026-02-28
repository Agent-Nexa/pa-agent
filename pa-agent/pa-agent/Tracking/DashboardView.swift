//
//  DashboardView.swift
//  pa-agent
//
//  Created by ZHEN YUAN on 28/2/2026.
//

import SwiftUI
import Charts

struct DashboardView: View {
    @ObservedObject var manager: TrackingManager
    var category: TrackingCategory
    
    @State private var selectedTimeframe: Timeframe = .month
    
    enum Timeframe: String, CaseIterable, Identifiable {
        case month = "Month"
        case year = "Year"
        var id: Self { self }
    }
    
    struct ChartData: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }
    
    var body: some View {
        VStack {
            Picker("Timeframe", selection: $selectedTimeframe) {
                ForEach(Timeframe.allCases) { timeframe in
                    Text(timeframe.rawValue).tag(timeframe)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            
            Chart(chartData()) { item in
                BarMark(
                    x: .value("Date", item.date, unit: chartStrideComponent(for: selectedTimeframe)),
                    y: .value("Total", item.value)
                )
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: chartStrideComponent(for: selectedTimeframe))) { value in
                    AxisGridLine()
                    AxisTick()
                    if value.as(Date.self) != nil {
                        AxisValueLabel(format: dateStyle(for: selectedTimeframe))
                    }
                }
            }
            .frame(height: 300)
            .padding()
            
            Spacer()
        }
        .navigationTitle("\(category.name) Dashboard")
    }
    
    private func chartStrideComponent(for timeframe: Timeframe) -> Calendar.Component {
        switch timeframe {
        case .month:
            return .day
        case .year:
            return .month
        }
    }
    
    private func dateStyle(for timeframe: Timeframe) -> Date.FormatStyle {
        switch timeframe {
        case .month:
            return .dateTime.day().month(.abbreviated)
        case .year:
            return .dateTime.month(.abbreviated)
        }
    }
    
    private func chartData() -> [ChartData] {
        let calendar = Calendar.current
        let now = Date()
        
        let records = manager.records(for: category.id)
        
        let filteredRecords: [TrackingRecord]
        
        switch selectedTimeframe {
        case .month:
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            filteredRecords = records.filter { $0.date >= startOfMonth }
        case .year:
            let startOfYear = calendar.date(from: calendar.dateComponents([.year], from: now))!
            filteredRecords = records.filter { $0.date >= startOfYear }
        }
        
        let grouped = Dictionary(grouping: filteredRecords) { record in
            switch selectedTimeframe {
            case .month:
                return calendar.dateComponents([.year, .month, .day], from: record.date)
            case .year:
                return calendar.dateComponents([.year, .month], from: record.date)
            }
        }
        
        var data: [ChartData] = []
        for (components, groupRecords) in grouped {
            let total = groupRecords.reduce(0) { $0 + $1.value }
            if let date = calendar.date(from: components) {
                data.append(ChartData(date: date, value: total))
            }
        }
        
        return data.sorted { $0.date < $1.date }
    }
}
