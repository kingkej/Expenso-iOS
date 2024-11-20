//
//  ChartView.swift
//  Expenso
//
//  Created by Sameer Nawaz on 15/03/21.
//

import SwiftUI
import Charts
//import DGCharts

//struct ChartView: UIViewRepresentable {
//    
//    var label: String, entries: [PieChartDataEntry]
//    
//    func makeUIView(context: Context) -> PieChartView {
//        let pieChartView = PieChartView()
//        pieChartView.holeColor = UIColor.primary_color
//        return pieChartView
//    }
//    
//    func updateUIView(_ uiView: PieChartView, context: Context) {
//        let dataSet = PieChartDataSet(entries: entries, label: label)
//        dataSet.valueFont = UIFont.init(name: "Inter-Bold", size: 18) ?? .systemFont(ofSize: 18, weight: .bold)
//        dataSet.entryLabelFont = UIFont.init(name: "Inter-Light", size: 14)
//        dataSet.colors = [UIColor(hex: "#DD222D")] + [UIColor(hex: "#F9AA07")] + [UIColor(hex: "#7220DC")] + [UIColor(hex: "#1DB0F3")] +
//                            [UIColor(hex: "#D21667")] + [UIColor(hex: "#EC5B2A")] + [UIColor(hex: "#FADFB4")] +
//                            [UIColor(hex: "#CCCF2E")] + [UIColor(hex: "#E1C10C")] + [UIColor(hex: "#716942")]
//        uiView.data = PieChartData(dataSet: dataSet)
//    }
//}

struct PieChartView: View {
    var entries: [ChartModel]
    
    var body: some View {
        Chart {
            ForEach(entries, id: \.transType) { entry in
                SectorMark(
                    angle: .value("Amount", entry.transAmount),
                    innerRadius: .ratio(0.5), // Controls the "hole" size
                    outerRadius: .ratio(1.0)
                )
                .foregroundStyle(by: .value("Type", entry.transType))
            }
        }
        .chartLegend(.visible) // Show the legend
        .chartLegend(position: .bottom) // Optional legend position
        .frame(height: 300) // Set the desired height
        .padding()
    }
}

struct ChartModel {
    var transType: String
    var transAmount: Double
    
    static func getTransaction(transactions: [ChartModel]) -> [ChartModel] {
        return transactions
    }
}
