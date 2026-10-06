import SwiftUI
import Charts

/// Double is used only for plotting; exact labels retain Decimal values.
struct InsightsTrendChart: View {
    let buckets: [InsightsBucket]
    let currency: String
    let title: String
    let calendar: Calendar
    @Binding var selectedDate: Date?

    var body: some View {
        let selectedID = selectedBucket?.id
        Chart(buckets, id: \.id) { bucket in
            // Explicit bounds draw columns from zero, inside the same calendar
            // interval used for selection. xStart/xEnd/y BarMark draws dashes.
            RectangleMark(xStart: .value("Period Start", bucket.id.addingTimeInterval(bucket.endExclusive.timeIntervalSince(bucket.id) * 0.15)),
                    xEnd: .value("Period End", bucket.endExclusive.addingTimeInterval(-bucket.endExclusive.timeIntervalSince(bucket.id) * 0.15)),
                    yStart: .value("\(title) in \(currency)", 0),
                    yEnd: .value("\(title) in \(currency)", NSDecimalNumber(decimal: bucket.amount).doubleValue))
                .foregroundStyle(.tint)
                .opacity(selectedID == nil || selectedID == bucket.id ? 1 : 0.35)
                .accessibilityLabel(bucket.range(calendar: calendar).formatted(calendar: calendar))
                .accessibilityValue(Money.format(bucket.amount, currency: currency))
            if selectedID == bucket.id {
                RuleMark(x: .value("Selected Period", midpoint(bucket)))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartGesture { proxy in
            // A tap keeps the selected detail visible and does not capture
            // vertical scrolling in the surrounding ScrollView.
            SpatialTapGesture().onEnded { value in
                proxy.selectXValue(at: value.location.x)
            }
        }
        .chartXScale(domain: (buckets.first?.id ?? .distantPast)...(buckets.last?.endExclusive ?? .distantFuture))
        .chartYScale(domain: 0...max(1, NSDecimalNumber(decimal: buckets.map(\.amount).max() ?? 0).doubleValue * 1.1))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(amount, format: .number.notation(.compactName))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisBuckets.map(midpoint)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self), let bucket = buckets.first(where: { midpoint($0) == date }) {
                        Text(axisLabel(bucket))
                    }
                }
            }
        }
        .chartYAxisLabel(currency)
        .frame(height: 200)
        .accessibilityRepresentation {
            // Keep every period selectable with VoiceOver without displaying
            // a second, duplicate table beneath the chart.
            VStack {
                ForEach(buckets) { bucket in
                    Button {
                        selectedDate = midpoint(bucket)
                    } label: {
                        Text("\(bucket.range(calendar: calendar).formatted(calendar: calendar)), \(Money.format(bucket.amount, currency: currency)), \(bucket.count) transactions")
                    }
                    .accessibilityHint("Shows this period's total and a button to view its transactions")
                    .accessibilityAddTraits(selectedID == bucket.id ? .isSelected : [])
                }
            }
        }
    }

    private func midpoint(_ bucket: InsightsBucket) -> Date {
        bucket.id.addingTimeInterval(bucket.endExclusive.timeIntervalSince(bucket.id) / 2)
    }

    private var axisBuckets: [InsightsBucket] {
        guard buckets.count > 5 else { return buckets }
        return (0..<5).map { buckets[$0 * (buckets.count - 1) / 4] }
    }

    private func axisLabel(_ bucket: InsightsBucket) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let maxDays = buckets.map { $0.range(calendar: calendar).dayCount }.max() ?? 1
        formatter.setLocalizedDateFormatFromTemplate(maxDays == 1 ? "MMMd" : maxDays <= 31 ? "yMMM" : "y")
        return formatter.string(from: bucket.id)
    }

    private var selectedBucket: InsightsBucket? {
        guard let selectedDate else { return nil }
        return buckets.first { selectedDate >= $0.id && selectedDate < $0.endExclusive }
    }
}

struct InsightsCategoryChart: View {
    let categories: [InsightsCategoryTotal]
    let catalog: [ExpenseCategory]
    let currency: String
    @Binding var selectedID: String?
    @ScaledMetric(relativeTo: .caption) private var categoryRowHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .caption) private var axisHeight: CGFloat = 32

    var body: some View {
        GeometryReader { geometry in
            chart(labelWidth: min(160, geometry.size.width * 0.45))
        }
        .frame(height: CGFloat(max(categories.count, 1)) * min(categoryRowHeight, 96) + min(axisHeight, 72))
        .accessibilityLabel("Ranked categories in \(currency)")
        .accessibilityHint("Category rows below show full names and open matching transactions.")
    }

    private func chart(labelWidth: CGFloat) -> some View {
        Chart(categories, id: \.id) { category in
            BarMark(x: .value("Amount in \(currency)", NSDecimalNumber(decimal: category.amount).doubleValue),
                    y: .value("Category", category.id))
                .foregroundStyle(.tint)
                .opacity(selectedID == nil || selectedID == category.id ? 1 : 0.35)
                .accessibilityLabel(name(category.id))
                .accessibilityValue(Money.format(category.amount, currency: currency))
        }
        .chartYScale(domain: categories.map(\.id))
        .chartYSelection(value: $selectedID)
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let id = value.as(String.self) {
                        Text(name(id))
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: labelWidth, alignment: .trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
        .chartXAxisLabel(currency)
    }

    private func name(_ id: String) -> String {
        catalog.first { $0.id == id }?.name ?? (id.isEmpty ? "Uncategorized" : id)
    }
}
