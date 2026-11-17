import XCTest
@testable import FelicityDashboard

final class EnergyChartDataTests: XCTestCase {
    func testNullShortAndNonfiniteRowsBreakOnlyTheAffectedSeries() {
        let chart = DashboardChart(samples: [
            [1, 10], [2, 20], nil, [3, 30], [4], [5, .nan], [6, 60], [7, .infinity], [8, 80]
        ], channels: 2)

        XCTAssertEqual(chart.segments(channel: 1).map { $0.map(\.id) }, [[0, 1], [3], [6], [8]])
        XCTAssertEqual(chart.segments(channel: 0).map { $0.map(\.id) }, [[0, 1], [3, 4, 5, 6, 7, 8]])
        XCTAssertEqual(chart.segments(channel: 1).last?.first?.x, 8)
        XCTAssertEqual(chart.segments(channel: 1).last?.first?.value, 80)
        XCTAssertTrue(chart.segments(channel: -1).isEmpty)
        XCTAssertTrue(chart.segments(channel: 2).isEmpty)
    }

    func testDomainUsesOnlySelectedFiniteChannelsAndPreservesSignedPower() {
        let chart = DashboardChart(samples: [[-400, 50_000], [200, 60_000], nil, [.nan, 70_000]], channels: 2)
        let power = chart.domain(channels: [0])
        XCTAssertLessThan(power.lowerBound, -400)
        XCTAssertGreaterThan(power.upperBound, 200)
        XCTAssertLessThan(power.upperBound, 1_000)
        XCTAssertTrue(power.contains(0))
        XCTAssertEqual(chart.domain(channels: [-1, 2]), 0...1)
    }

    func testFlatVoltageHasReadablePaddingAndZeroPowerHasFiniteRange() {
        let voltage = DashboardChart(samples: [[230], [230]], channels: 1)
            .domain(channels: [0], includeZero: false)
        XCTAssertLessThan(voltage.lowerBound, 230)
        XCTAssertGreaterThan(voltage.upperBound, 230)
        XCTAssertGreaterThan(voltage.lowerBound, 200)
        XCTAssertEqual(DashboardChart(samples: [[0], [0]], channels: 1).domain(channels: [0]), 0...1)
    }

    func testAllMissingOrInvalidDataHasNoSegments() {
        let chart = DashboardChart(samples: [nil, [], [.nan], [.infinity], [-.infinity]], channels: 1)
        XCTAssertTrue(chart.segments(channel: 0).isEmpty)
        XCTAssertEqual(chart.domain(channels: [0]), 0...1)
        XCTAssertTrue(DashboardChart().segments(channel: 0).isEmpty)
    }

    func testPanelsSeparateDifferentUnitsAndMatchServerChannelOrder() {
        XCTAssertEqual(DashboardMetric.solar.chartPanels.first?.series.map(\.name), ["Total", "PV1", "PV2"])
        XCTAssertEqual(DashboardMetric.solar.chartPanels.map { $0.series.map(\.id) }, [[0, 1, 2]])
        XCTAssertEqual(DashboardMetric.load.chartPanels.first?.series.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(DashboardMetric.battery.chartPanels.map(\.unit), ["%", "W"])
        XCTAssertEqual(DashboardMetric.battery.chartPanels.map { $0.series.map(\.id) }, [[0], [1]])
        XCTAssertEqual(DashboardMetric.grid.chartPanels.map(\.unit), ["V", "W"])
        XCTAssertEqual(DashboardMetric.grid.chartPanels.map { $0.series.map(\.id) }, [[0, 1, 2], [3]])
        XCTAssertEqual(DashboardMetric.system.chartPanels.map(\.unit), ["%", "°C"])
        XCTAssertEqual(DashboardMetric.system.chartPanels.map { $0.series.map(\.id) }, [[0, 1, 3], [2]])
        XCTAssertEqual(DashboardMetric.system.chartPanels.first?.series.map(\.name), ["CPU", "RAM", "Disk"])
        XCTAssertEqual(DashboardMetric.today.chartPanels.first?.series.map(\.name), ["Solar", "Load", "PV1", "PV2"])
        XCTAssertEqual(DashboardMetric.today.chartPanels.map { $0.series.map(\.id) }, [[0, 1, 2, 3]])
        XCTAssertEqual(DashboardMetric.today.chartPanels.map(\.unit), ["W"])
        for metric in DashboardMetric.allCases {
            XCTAssertEqual(Set(metric.chartPanels.map(\.id)).count, metric.chartPanels.count)
        }
    }

    func testSolarSinglePanelKeepsPVSeriesAndScalesToVisibleChannels() throws {
        let chart = DashboardChart(samples: [[5_200, 5_000, 200], [6_300, 6_000, 300]], channels: 3)
        let panels = DashboardMetric.solar.chartPanels
        XCTAssertEqual(panels.count, 1)
        let panel = try XCTUnwrap(panels.first)
        let pv1 = try XCTUnwrap(panel.series.first { $0.name == "PV1" })
        let pv2 = try XCTUnwrap(panel.series.first { $0.name == "PV2" })

        XCTAssertEqual(panel.unit, "W")
        XCTAssertEqual(chart.segments(channel: pv1.id).flatMap { $0.map(\.value) }, [5_000, 6_000])
        XCTAssertEqual(chart.segments(channel: pv2.id).flatMap { $0.map(\.value) }, [200, 300])
        XCTAssertGreaterThan(chart.domain(channels: panel.series.map(\.id)).upperBound, 6_300)
        let visibleChannels = panel.series.filter { $0.id == pv2.id }.map(\.id)
        let visibleDomain = chart.domain(channels: visibleChannels)
        XCTAssertGreaterThan(visibleDomain.upperBound, 300)
        XCTAssertLessThan(visibleDomain.upperBound, 1_000)
    }

    func testDayMetadataDecodesOffsetAndOneHundredEightyActualBuckets() throws {
        let chart = try decode([
            "metric": "pv", "channels": 3, "interval_minutes": 8,
            "start": "2026-11-16T00:00:00+01:00", "end": "2026-11-17T00:00:00+01:00",
            "samples": Array(repeating: [10.0, 6.0, 4.0], count: 180)
        ])
        let start = try XCTUnwrap(chart.start)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 23)))
        XCTAssertEqual(start, expected)
        XCTAssertEqual(chart.metric, .solar)
        XCTAssertEqual(chart.intervalMinutes, 8)
        XCTAssertEqual(chart.date(at: 0, metric: .solar), start)
        XCTAssertEqual(try XCTUnwrap(chart.date(at: 179, metric: .solar)).timeIntervalSince(start), 179 * 480, accuracy: 0.001)
        XCTAssertNil(chart.date(at: 180, metric: .solar))
    }

    func testSystemFractionalMetadataProducesTenMinuteScaleInsteadOfDayScale() throws {
        let chart = try decode([
            "metric": "system", "channels": 4, "interval_seconds": 10,
            "start": "2026-11-16T12:00:00.125000+01:00", "end": "2026-11-16T12:10:00.125000+01:00",
            "samples": Array(repeating: [40.0, 60.0, 55.0, 25.0], count: 60)
        ])
        let start = try XCTUnwrap(chart.start)
        XCTAssertEqual(chart.metric, .system)
        XCTAssertEqual(chart.intervalSeconds, 10)
        XCTAssertEqual(try XCTUnwrap(chart.end).timeIntervalSince(start), 600, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(chart.date(at: 59, metric: .system)).timeIntervalSince(start), 590, accuracy: 0.001)
        var conflictingInterval = chart
        conflictingInterval.intervalSeconds = 999
        XCTAssertEqual(conflictingInterval.date(at: 59, metric: .system), chart.date(at: 59, metric: .system))
    }

    func testOffsetFreeStartUsesUTCAndIntervalMetadataWhenEndIsAbsent() throws {
        let chart = try decode([
            "channels": 1, "interval_minutes": 8,
            "start": "1970-01-01T00:00:00", "samples": [[1], [2]]
        ])
        XCTAssertEqual(chart.start, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(chart.date(at: 1, metric: .solar), Date(timeIntervalSince1970: 480))
    }

    func testLegacyAndInvalidMetadataDoNotInventTimestampsOrLoseSamples() throws {
        let legacy = try decode(["channels": 1, "samples": [[1], NSNull(), [3]]])
        XCTAssertNil(legacy.start)
        XCTAssertNil(legacy.date(at: 0, metric: .system))
        XCTAssertEqual(legacy.segments(channel: 0).map { $0.map(\.id) }, [[0], [2]])
        let invalid = try decode([
            "channels": 1, "start": "not-a-date", "interval_seconds": -10, "samples": [[1]]
        ])
        XCTAssertNil(invalid.date(at: 0, metric: .solar))
        XCTAssertNil(invalid.intervalSeconds)
        XCTAssertEqual(invalid.segments(channel: 0).first?.first?.value, 1)
    }

    private func decode(_ object: [String: Any]) throws -> DashboardChart {
        try DashboardChart.decode(JSONSerialization.data(withJSONObject: object))
    }
}
