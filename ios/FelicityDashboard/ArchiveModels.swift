import Foundation
import SwiftUI

enum ArchiveActivityKind: String, CaseIterable, Codable, Hashable, Sendable {
    case person
    case animal
    case vehicle
    case face
    case ring

    var title: String {
        switch self {
        case .person: return "PERSON"
        case .animal: return "ANIMAL"
        case .vehicle: return "VEHICLE"
        case .face: return "FACE"
        case .ring: return "RING"
        }
    }

    var color: Color {
        switch self {
        case .person, .face: return Color(red: 0.07, green: 0.68, blue: 0.94)
        case .animal: return Color(red: 0.50, green: 0.25, blue: 0.94)
        case .vehicle: return Color(red: 0.48, green: 0.78, blue: 0.18)
        case .ring: return Color(red: 0.15, green: 0.73, blue: 0.61)
        }
    }

    /// Matches Android's draw order for combined ONVIF activity masks. Later
    /// classes are painted above earlier ones on the single compact timeline.
    var timelineLayer: Int {
        switch self {
        case .person: return 0
        case .face: return 1
        case .animal: return 2
        case .vehicle: return 3
        case .ring: return 4
        }
    }

    init?(_ eventClass: ThreeEyeEventClass) {
        switch eventClass {
        case .person: self = .person
        case .animal: self = .animal
        case .vehicle: self = .vehicle
        case .face: self = .face
        }
    }
}

struct ArchiveActivityBoundary: Equatable, Sendable {
    let time: Date
    let kinds: Set<ArchiveActivityKind>
    let asserted: Bool
}

struct ArchiveInterval: Identifiable, Equatable, Sendable {
    let kind: ArchiveActivityKind
    let start: Date
    let end: Date

    var id: String { "\(kind.rawValue)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)" }
}

enum ArchiveTimelineRules {
    static let context: TimeInterval = 6
    static let markerTTL: TimeInterval = 30 * 60
    static let minimumVisibleSpan: TimeInterval = 15 * 60
    static let maximumVisibleSpan: TimeInterval = 24 * 60 * 60
    static let timelineCacheDays = 3

    static func intervals(from boundaries: [ArchiveActivityBoundary]) -> [ArchiveInterval] {
        var opened: [ArchiveActivityKind: Date] = [:]
        var output: [ArchiveInterval] = []
        for boundary in boundaries.sorted(by: { $0.time < $1.time }) {
            for kind in boundary.kinds {
                if boundary.asserted {
                    guard let start = opened.removeValue(forKey: kind), boundary.time > start,
                          boundary.time.timeIntervalSince(start) <= 10 * 60 else {
                        if kind == .ring {
                            output.append(.init(kind: kind, start: boundary.time.addingTimeInterval(-context), end: boundary.time.addingTimeInterval(context)))
                        }
                        continue
                    }
                    output.append(.init(kind: kind, start: start.addingTimeInterval(-context), end: boundary.time.addingTimeInterval(context)))
                } else {
                    opened[kind] = boundary.time
                }
            }
        }
        return merge(output.sorted(by: { $0.start < $1.start }))
    }

    static func nearestRecordedTime(to target: Date, in intervals: [ArchiveInterval]) -> Date? {
        var best: Date?
        var distance = TimeInterval.greatestFiniteMagnitude
        for interval in intervals {
            let candidate: Date
            if target < interval.start { candidate = interval.start }
            else if target > interval.end { candidate = interval.end }
            else { candidate = target }
            let next = abs(candidate.timeIntervalSince(target))
            if next < distance || (next == distance && candidate < (best ?? .distantFuture)) {
                best = candidate
                distance = next
            }
        }
        return best
    }

    /// Resolves Play against the day currently shown by the timeline. The last
    /// decoded frame may belong to another day while fresh metadata is loading;
    /// carrying that absolute date into PLAY would silently jump back to it.
    static func preferredPlaybackTarget(
        currentTime: Date?,
        visibleStart: Date,
        visibleSpan: TimeInterval,
        intervals: [ArchiveInterval],
        keyframeLead: TimeInterval = 0,
        calendar: Calendar = .current
    ) -> Date? {
        guard !intervals.isEmpty else { return nil }
        if let currentTime,
           currentTime >= visibleStart,
           currentTime <= visibleStart.addingTimeInterval(visibleSpan),
           playbackEnd(for: currentTime, in: intervals, keyframeLead: keyframeLead) != nil {
            return currentTime
        }
        let focus = visibleStart.addingTimeInterval(visibleSpan / 2)
        let dayStart = calendar.startOfDay(for: focus)
        let reference = currentTime ?? focus
        let clock = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: reference)
        let requested = calendar.date(byAdding: clock, to: dayStart) ?? focus
        return nearestRecordedTime(to: requested, in: intervals)
    }

    /// Returns the end of the continuous AI-covered segment selected for playback.
    /// A replay server may return a keyframe just before the requested boundary, so
    /// tolerate a short lead-in while still refusing unrelated archive motion.
    static func playbackEnd(
        for target: Date,
        in intervals: [ArchiveInterval],
        keyframeLead: TimeInterval = 0
    ) -> Date? {
        let coverage = mergedCoverage(intervals)
        guard let selected = coverage.first(where: {
            target >= $0.start.addingTimeInterval(-keyframeLead) && target <= $0.end
        }) else { return nil }
        return selected.end
    }

    static func nextPlaybackStart(after time: Date, in intervals: [ArchiveInterval]) -> Date? {
        mergedCoverage(intervals).first(where: { $0.start > time.addingTimeInterval(0.5) })?.start
    }

    static func adaptiveSpan(eventCount: Int) -> TimeInterval {
        if eventCount <= 6 { return 24 * 60 * 60 }
        if eventCount <= 18 { return 12 * 60 * 60 }
        if eventCount <= 48 { return 6 * 60 * 60 }
        return 3 * 60 * 60
    }

    static func zoomedViewport(
        baseStart: Date,
        baseSpan: TimeInterval,
        magnification: Double,
        anchorRatio: Double,
        dayStart: Date
    ) -> (start: Date, span: TimeInterval) {
        let safeMagnification = max(0.01, magnification)
        let span = min(maximumVisibleSpan, max(minimumVisibleSpan, baseSpan / safeMagnification))
        let ratio = min(1, max(0, anchorRatio))
        let anchor = baseStart.addingTimeInterval(baseSpan * ratio)
        let proposed = anchor.addingTimeInterval(-span * ratio)
        let latest = dayStart.addingTimeInterval(maximumVisibleSpan - span)
        return (min(max(dayStart, proposed), latest), span)
    }

    static func zoomedContinuousViewport(
        baseStart: Date,
        baseSpan: TimeInterval,
        magnification: Double,
        anchorRatio: Double
    ) -> (start: Date, span: TimeInterval) {
        let safeMagnification = max(0.01, magnification)
        let span = min(maximumVisibleSpan, max(minimumVisibleSpan, baseSpan / safeMagnification))
        let ratio = min(1, max(0, anchorRatio))
        let anchor = baseStart.addingTimeInterval(baseSpan * ratio)
        return (anchor.addingTimeInterval(-span * ratio), span)
    }

    static func cachedTimelineWindow(
        centeredOn center: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let centerDay = calendar.startOfDay(for: center)
        let start = calendar.date(byAdding: .day, value: -1, to: centerDay) ?? centerDay.addingTimeInterval(-maximumVisibleSpan)
        let end = calendar.date(byAdding: .day, value: timelineCacheDays, to: start) ?? start.addingTimeInterval(Double(timelineCacheDays) * maximumVisibleSpan)
        return (start, end)
    }

    static func cachedTimelineCovers(
        visibleStart: Date,
        visibleSpan: TimeInterval,
        loadedStart: Date?,
        loadedEnd: Date?,
        preloadMargin: TimeInterval = 12 * 60 * 60
    ) -> Bool {
        guard let loadedStart, let loadedEnd else { return false }
        return visibleStart >= loadedStart.addingTimeInterval(preloadMargin)
            && visibleStart.addingTimeInterval(visibleSpan) <= loadedEnd.addingTimeInterval(-preloadMargin)
    }

    private static func merge(_ source: [ArchiveInterval]) -> [ArchiveInterval] {
        var result: [ArchiveInterval] = []
        let grouped = Dictionary(grouping: source, by: \.kind)
        for kind in ArchiveActivityKind.allCases {
            var mergedKind: [ArchiveInterval] = []
            for interval in grouped[kind, default: []].sorted(by: { $0.start < $1.start }) {
                guard let previous = mergedKind.last, interval.start <= previous.end else {
                    mergedKind.append(interval)
                    continue
                }
                mergedKind[mergedKind.count - 1] = .init(
                    kind: kind,
                    start: previous.start,
                    end: max(previous.end, interval.end)
                )
            }
            result.append(contentsOf: mergedKind)
        }
        return result.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.kind.timelineLayer < $1.kind.timelineLayer
        }
    }

    private static func mergedCoverage(_ source: [ArchiveInterval]) -> [(start: Date, end: Date)] {
        var result: [(start: Date, end: Date)] = []
        for interval in source.sorted(by: { $0.start < $1.start }) {
            guard let previous = result.last, interval.start <= previous.end else {
                result.append((interval.start, interval.end))
                continue
            }
            result[result.count - 1] = (previous.start, max(previous.end, interval.end))
        }
        return result
    }
}

@MainActor
final class ArchiveMarkerStore {
    static let shared = ArchiveMarkerStore()
    private let defaults: UserDefaults
    private let timeKey = "archive.marker.time"
    private let touchedKey = "archive.marker.touched"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func value(now: Date = .now) -> Date? {
        let touched = defaults.double(forKey: touchedKey)
        guard touched > 0, now.timeIntervalSince1970 - touched <= ArchiveTimelineRules.markerTTL else {
            clear()
            return nil
        }
        let time = defaults.double(forKey: timeKey)
        return time > 0 ? Date(timeIntervalSince1970: time) : nil
    }

    func set(_ value: Date, now: Date = .now) {
        defaults.set(value.timeIntervalSince1970, forKey: timeKey)
        defaults.set(now.timeIntervalSince1970, forKey: touchedKey)
    }

    func clear() {
        defaults.removeObject(forKey: timeKey)
        defaults.removeObject(forKey: touchedKey)
    }
}

enum OnvifActivityDecoder {
    static func decodeXML(_ xml: String) -> [ArchiveActivityBoundary] {
        guard let encoded = capture(xml, #"<(?:[A-Za-z_][\w.-]*:)?Metadata\b[^>]*>([^<]+)</(?:[A-Za-z_][\w.-]*:)?Metadata>"#),
              let payload = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)) else { return [] }
        return decode(payload)
    }

    static func decode(_ payload: Data) -> [ArchiveActivityBoundary] {
        guard let batch = try? ProtoMessage(payload), batch.string(1) == "A" else { return [] }
        return batch.bytes(2).compactMap { encoded in
            guard let event = try? ProtoMessage(encoded), let timestampUS = event.varint(1), timestampUS > 0,
                  let detailData = event.bytes(3).first, let detail = try? ProtoMessage(detailData) else { return nil }
            let mask: UInt64
            if let typeData = detail.bytes(5).first, let type = try? ProtoMessage(typeData) { mask = type.varint(1) ?? 0 }
            else { mask = 0 }
            var kinds = Set<ArchiveActivityKind>()
            if detail.has(6) { kinds.insert(.ring) }
            if mask & 2 != 0 { kinds.insert(.person) }
            if mask & 4 != 0 { kinds.insert(.animal) }
            if mask & 8 != 0 { kinds.insert(.vehicle) }
            guard !kinds.isEmpty else { return nil }
            return ArchiveActivityBoundary(
                time: Date(timeIntervalSince1970: Double(timestampUS) / 1_000_000),
                kinds: kinds,
                asserted: (detail.varint(101) ?? 0) != 0
            )
        }
    }

    private static func capture(_ input: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: input) else { return nil }
        return String(input[range])
    }

    private struct ProtoField {
        let number: Int
        let wire: Int
        let numberValue: UInt64
        let bytes: Data?
    }

    private struct ProtoMessage {
        let fields: [ProtoField]

        init(_ data: Data) throws {
            let bytes = [UInt8](data)
            var cursor = 0
            var values: [ProtoField] = []
            while cursor < bytes.count {
                let tag = try Self.varint(bytes, &cursor)
                let number = Int(tag >> 3), wire = Int(tag & 7)
                guard number > 0 else { throw ArchiveError.invalidMetadata }
                switch wire {
                case 0:
                    values.append(.init(number: number, wire: wire, numberValue: try Self.varint(bytes, &cursor), bytes: nil))
                case 1:
                    guard cursor + 8 <= bytes.count else { throw ArchiveError.invalidMetadata }
                    var value: UInt64 = 0
                    for offset in 0..<8 { value |= UInt64(bytes[cursor + offset]) << UInt64(offset * 8) }
                    cursor += 8
                    values.append(.init(number: number, wire: wire, numberValue: value, bytes: nil))
                case 2:
                    let count = Int(try Self.varint(bytes, &cursor))
                    guard count >= 0, cursor + count <= bytes.count else { throw ArchiveError.invalidMetadata }
                    values.append(.init(number: number, wire: wire, numberValue: 0, bytes: Data(bytes[cursor..<(cursor + count)])))
                    cursor += count
                case 5:
                    guard cursor + 4 <= bytes.count else { throw ArchiveError.invalidMetadata }
                    var value: UInt64 = 0
                    for offset in 0..<4 { value |= UInt64(bytes[cursor + offset]) << UInt64(offset * 8) }
                    cursor += 4
                    values.append(.init(number: number, wire: wire, numberValue: value, bytes: nil))
                default:
                    throw ArchiveError.invalidMetadata
                }
            }
            fields = values
        }

        func varint(_ number: Int) -> UInt64? { fields.first(where: { $0.number == number && $0.wire == 0 })?.numberValue }
        func bytes(_ number: Int) -> [Data] { fields.compactMap { $0.number == number && $0.wire == 2 ? $0.bytes : nil } }
        func string(_ number: Int) -> String { bytes(number).first.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        func has(_ number: Int) -> Bool { fields.contains(where: { $0.number == number }) }

        private static func varint(_ bytes: [UInt8], _ cursor: inout Int) throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard cursor < bytes.count else { throw ArchiveError.invalidMetadata }
                let next = bytes[cursor]
                cursor += 1
                value |= UInt64(next & 0x7f) << UInt64(shift)
                if next & 0x80 == 0 { return value }
            }
            throw ArchiveError.invalidMetadata
        }
    }
}

enum ReplayClock {
    private static let ntpEpoch: UInt64 = 2_208_988_800
    private static let fractionScale = 4_294_967_296.0

    static func date(fromRTP packet: Data) -> Date? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 28, bytes[0] & 0xc0 == 0x80, bytes[0] & 0x10 != 0 else { return nil }
        let extensionOffset = 12 + Int(bytes[0] & 0x0f) * 4
        guard extensionOffset + 16 <= bytes.count,
              read16(bytes, extensionOffset) == 0xabac,
              read16(bytes, extensionOffset + 2) >= 3 else { return nil }
        let seconds = UInt64(read32(bytes, extensionOffset + 4))
        let fraction = UInt64(read32(bytes, extensionOffset + 8))
        guard seconds >= ntpEpoch else { return nil }
        return Date(timeIntervalSince1970: Double(seconds - ntpEpoch) + Double(fraction) / fractionScale)
    }

    static func rtpTimestamp(_ packet: Data) -> UInt32? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 12, bytes[0] & 0xc0 == 0x80 else { return nil }
        return read32(bytes, 4)
    }

    static func date(rtpTimestamp: UInt32, anchorTimestamp: UInt32, anchorDate: Date) -> Date {
        let delta = Int64(Int32(bitPattern: rtpTimestamp &- anchorTimestamp))
        return anchorDate.addingTimeInterval(Double(delta) / 90_000)
    }

    static func rangeStart(_ header: String?) -> Date? {
        guard let header, let clock = header.range(of: "clock=", options: .caseInsensitive) else { return nil }
        let suffix = header[clock.upperBound...]
        let raw = String(suffix.prefix { $0 != "-" && $0 != ";" }).trimmingCharacters(in: .whitespaces)
        return formatter.date(from: raw)
    }

    static func rtpInfoTimestamp(_ header: String?) -> UInt32? {
        guard let header, let range = header.range(of: #"(?i)rtptime=([0-9]+)"#, options: .regularExpression) else { return nil }
        let match = header[range]
        return UInt32(match.split(separator: "=").last ?? "")
    }

    static func clock(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)
        value.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return value
    }()

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

enum ArchiveError: LocalizedError {
    case noRecording
    case noReplayURI
    case invalidMetadata
    case response(String)

    var errorDescription: String? {
        switch self {
        case .noRecording: return "This camera has no Profile G recording"
        case .noReplayURI: return "Recorder did not return a replay URI"
        case .invalidMetadata: return "Invalid ONVIF Profile G archive metadata"
        case let .response(value): return value
        }
    }
}
