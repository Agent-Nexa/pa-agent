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
    @State var category: TrackingCategory? // Make optional and mutable for switching
    
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
            if manager.categories.isEmpty {
                Text("No categories available.")
                    .foregroundColor(.secondary)
                    .padding()
                Spacer()
            } else {
                if let currentCategory = category ?? manager.categories.first {
                    HStack {
                        Text("Category")
                            .font(.headline)
                        Spacer()
                        Picker("Category", selection: Binding(
                            get: { self.category?.id ?? manager.categories.first?.id },
                            set: { newValue in
                                if let newCat = manager.categories.first(where: { $0.id == newValue }) {
                                    self.category = newCat
                                }
                            }
                        )) {
                            ForEach(manager.categories) { cat in
                                Text(cat.name).tag(cat.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .padding(.horizontal)
                    .padding(.top)

                    Picker("Timeframe", selection: $selectedTimeframe) {
                        ForEach(Timeframe.allCases) { timeframe in
                            Text(timeframe.rawValue).tag(timeframe)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    
                    Chart(chartData(for: currentCategory)) { item in
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
            }
        }
        .navigationTitle(category != nil ? "\(category!.name) Dashboard" : "Dashboard")
        .navigationBarTitleDisplayMode(.inline)
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
    
    private func chartData(for categoryToChart: TrackingCategory) -> [ChartData] {
        let calendar = Calendar.current
        let now = Date()
        
        let records = manager.records(for: categoryToChart.id)
        
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
