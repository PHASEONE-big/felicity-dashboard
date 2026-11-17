import SwiftUI

/// One lightweight drawing surface per unit, instead of a view per data point.
struct EnergyChartPanelView: View, Equatable {
    let metric: DashboardMetric
    let panel: EnergyChartPanel
    let chart: DashboardChart
    @State private var hidden: Set<Int> = []
    @State private var selectedIndex: Int?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.metric == rhs.metric && lhs.panel == rhs.panel && lhs.chart == rhs.chart
    }

    private let colors: [Color] = [FelicityPalette.accent, Color(red: 1, green: 0.72, blue: 0.36),
                                  Color(red: 0.42, green: 0.68, blue: 1), Color(red: 0.78, green: 0.57, blue: 1)]
    private var visible: [EnergyChartSeries] { panel.series.filter { !hidden.contains($0.id) } }
    private var domain: ClosedRange<Double> {
        if panel.unit == "%" { return 0...100 }
        return chart.domain(channels: visible.map(\.id), includeZero: panel.unit == "W")
    }
    private var hasData: Bool { panel.series.contains { !chart.segments(channel: $0.id).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(panel.title).font(.headline)
                Spacer()
                Text(panel.unit).font(.caption.weight(.semibold)).foregroundStyle(FelicityPalette.secondary)
            }
            // Each series has a persistent, named legend and an optional reading.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { legend }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) { legend }
            }
            if hasData {
                plot
                    .frame(height: 250)
                HStack(spacing: 6) {
                    Image(systemName: selectedIndex == nil ? "hand.draw" : "clock")
                    Text(selectedIndex.map { timeLabel($0, detail: true) } ?? "Touch and slide to inspect")
                    Spacer()
                    if selectedIndex != nil {
                        Button("Latest") { selectedIndex = nil }.font(.caption.weight(.semibold))
                    }
                }
                .font(.caption).foregroundStyle(FelicityPalette.secondary)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "chart.xyaxis.line").font(.title)
                    Text("No measurements in this period")
                    Text("Gaps are left empty, never filled with zero.").font(.caption)
                }
                .foregroundStyle(FelicityPalette.secondary)
                .frame(maxWidth: .infinity, minHeight: 250)
            }
        }
        .padding(20)
        .background(FelicityPalette.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(FelicityPalette.secondary.opacity(0.12)))
        .onChange(of: chart) { _ in
            if let selectedIndex, selectedIndex >= chart.samples.count { self.selectedIndex = nil }
        }
    }

    private var legend: some View {
        ForEach(panel.series) { series in
            Button {
                if hidden.contains(series.id) { hidden.remove(series.id) }
                else if visible.count > 1 { hidden.insert(series.id) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(color(series.id)).frame(width: 7, height: 7)
                        Text(series.name).font(.caption.weight(.medium)).lineLimit(1)
                    }
                    Text(reading(series.id)).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1)
                }
                .frame(minHeight: 44, alignment: .leading)
                .opacity(hidden.contains(series.id) ? 0.35 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(series.name), \(reading(series.id)), \(hidden.contains(series.id) ? "hidden" : "visible")")
            .accessibilityHint("Toggle this series")
        }
    }

    private var plot: some View {
        GeometryReader { geometry in
            let rect = plotRect(geometry.size)
            let bounds = domain
            let segments = visible.map { ($0.id, chart.segments(channel: $0.id)) }
            Canvas(rendersAsynchronously: true) { context, size in
                // Deliberately no per-sample animations, interpolation or shadows.
                for tick in 0...4 {
                    let fraction = Double(tick) / 4
                    let y = rect.maxY - rect.height * fraction
                    var grid = Path()
                    grid.move(to: CGPoint(x: rect.minX, y: y)); grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                    context.stroke(grid, with: .color(FelicityPalette.secondary.opacity(0.13)), lineWidth: 0.5)
                    let value = bounds.lowerBound + (bounds.upperBound - bounds.lowerBound) * fraction
                    context.draw(Text(axisValue(value)).font(.system(size: 11)).foregroundColor(FelicityPalette.secondary),
                                 at: CGPoint(x: rect.minX - 9, y: y), anchor: .trailing)
                }
                for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let x = rect.minX + rect.width * fraction
                    let index = Int((Double(max(0, chart.samples.count - 1)) * fraction).rounded())
                    context.draw(Text(timeLabel(index)).font(.system(size: 11)).foregroundColor(FelicityPalette.secondary),
                                 at: CGPoint(x: x, y: rect.maxY + 19), anchor: fraction == 0 ? .leading : fraction == 1 ? .trailing : .center)
                }
                var clipped = context
                clipped.clip(to: Path(rect))
                for (channel, runs) in segments {
                    for run in runs {
                        var path = Path()
                        for (offset, point) in run.enumerated() {
                            let position = position(index: point.id, value: point.value, rect: rect, bounds: bounds)
                            if offset == 0 { path.move(to: position) } else { path.addLine(to: position) }
                        }
                        if run.count == 1, let point = run.first {
                            let p = position(index: point.id, value: point.value, rect: rect, bounds: bounds)
                            clipped.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(color(channel)))
                        } else {
                            clipped.stroke(path, with: .color(color(channel)), style: StrokeStyle(lineWidth: channel == 0 ? 2.2 : 1.7, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
                if let selectedIndex {
                    let x = position(index: selectedIndex, value: bounds.lowerBound, rect: rect, bounds: bounds).x
                    var rule = Path(); rule.move(to: CGPoint(x: x, y: rect.minY)); rule.addLine(to: CGPoint(x: x, y: rect.maxY))
                    clipped.stroke(rule, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    for series in visible {
                        if let value = sample(selectedIndex, series.id) {
                            let p = position(index: selectedIndex, value: value, rect: rect, bounds: bounds)
                            clipped.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color(series.id)))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 8)
                .onChanged { gesture in
                    guard abs(gesture.translation.width) > abs(gesture.translation.height) else { return }
                    let fraction = min(1, max(0, (gesture.location.x - rect.minX) / max(1, rect.width)))
                    selectedIndex = min(max(0, chart.samples.count - 1), Int((fraction * Double(max(1, chart.samples.count - 1))).rounded()))
                })
            .simultaneousGesture(SpatialTapGesture().onEnded { gesture in
                let fraction = min(1, max(0, (gesture.location.x - rect.minX) / max(1, rect.width)))
                selectedIndex = min(max(0, chart.samples.count - 1), Int((fraction * Double(max(1, chart.samples.count - 1))).rounded()))
            })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(panel.title) chart in \(panel.unit)")
        .accessibilityValue(visible.map { "\($0.name) \(reading($0.id))" }.joined(separator: ", "))
        .accessibilityAdjustableAction { direction in
            let current = selectedIndex ?? latestIndex
            selectedIndex = min(max(0, chart.samples.count - 1), max(0, current + (direction == .increment ? 1 : -1)))
        }
    }

    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: 51, y: 8, width: max(1, size.width - 57), height: max(1, size.height - 36))
    }
    private func position(index: Int, value: Double, rect: CGRect, bounds: ClosedRange<Double>) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * Double(index) / Double(max(1, chart.samples.count - 1)),
                y: rect.maxY - rect.height * (value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound))
    }
    private func sample(_ index: Int, _ channel: Int) -> Double? {
        guard chart.samples.indices.contains(index), let row = chart.samples[index], row.indices.contains(channel), row[channel].isFinite else { return nil }
        return row[channel]
    }
    private var latestIndex: Int {
        chart.samples.lastIndex(where: { row in row?.contains(where: \.isFinite) == true }) ?? 0
    }
    private func reading(_ channel: Int) -> String {
        let index = selectedIndex ?? latestIndex
        guard let value = sample(index, channel) else { return "— \(panel.unit)" }
        return value.formatted(.number.precision(.fractionLength(panel.unit == "V" || panel.unit == "°C" ? 1 : 0))) + " " + panel.unit
    }
    private func timeLabel(_ index: Int, detail: Bool = false) -> String {
        guard let date = chart.date(at: index, metric: metric) else { return detail ? "Sample \(index + 1)" : "\(index + 1)" }
        return date.formatted(detail && metric == .system ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
    }
    private func color(_ channel: Int) -> Color {
        // Keep string colors the same in Solar and Today despite channel order.
        switch panel.series.first(where: { $0.id == channel })?.name {
        case "PV1": return colors[2]
        case "PV2": return colors[3]
        default: return colors[max(0, channel) % colors.count]
        }
    }
    private func axisValue(_ value: Double) -> String {
        if abs(value) >= 1000 { return (value / 1000).formatted(.number.precision(.fractionLength(1))) + "k" }
        return value.formatted(.number.precision(.fractionLength(panel.unit == "V" || panel.unit == "°C" ? 1 : 0)))
    }
}
