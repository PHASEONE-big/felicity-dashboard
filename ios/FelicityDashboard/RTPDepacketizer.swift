import Foundation

struct VideoAccessUnit: Sendable {
    let annexB: Data
    let rtpTimestamp: UInt32
    let isKeyframe: Bool
    let archiveTime: Date?

    init(annexB: Data, rtpTimestamp: UInt32, isKeyframe: Bool, archiveTime: Date? = nil) {
        self.annexB = annexB
        self.rtpTimestamp = rtpTimestamp
        self.isKeyframe = isKeyframe
        self.archiveTime = archiveTime
    }
}

/// Reassembles H.264/H.265 RTP payloads into complete Annex-B access units.
final class RTPDepacketizer {
    private let isHEVC: Bool
    private let output: (VideoAccessUnit) -> Void
    private var access = Data()
    private var timestamp: UInt32?
    private var archiveTime: Date?
    private var expectedSequence: UInt16?
    private var keyframe = false
    private var fragmentOpen = false

    init(isHEVC: Bool, output: @escaping (VideoAccessUnit) -> Void) {
        self.isHEVC = isHEVC
        self.output = output
        access.reserveCapacity(256 * 1024)
    }

    func reset() {
        access.removeAll(keepingCapacity: true)
        timestamp = nil
        archiveTime = nil
        expectedSequence = nil
        keyframe = false
        fragmentOpen = false
    }

    func accept(_ packet: Data, archiveTime nextArchiveTime: Date? = nil) {
        let bytes = [UInt8](packet)
        guard let payload = Self.payloadRange(bytes) else { return }
        let sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let nextTimestamp = Self.readUInt32(bytes, 4)
        if let expectedSequence, expectedSequence != sequence {
            access.removeAll(keepingCapacity: true)
            keyframe = false
            fragmentOpen = false
        }
        expectedSequence = sequence &+ 1
        if let timestamp, timestamp != nextTimestamp { emit() }
        timestamp = nextTimestamp
        if archiveTime == nil { archiveTime = nextArchiveTime }
        if isHEVC { appendH265(bytes, payload) } else { appendH264(bytes, payload) }
        if bytes[1] & 0x80 != 0 { emit() }
    }

    private func appendH264(_ packet: [UInt8], _ payload: Range<Int>) {
        guard let first = packet[safe: payload.lowerBound] else { return }
        let type = first & 0x1f
        if (1...23).contains(type) {
            appendNAL(packet[payload])
            keyframe = keyframe || type == 5
            fragmentOpen = false
        } else if type == 24 {
            var cursor = payload.lowerBound + 1
            while cursor + 2 <= payload.upperBound {
                let size = Int(packet[cursor]) << 8 | Int(packet[cursor + 1])
                cursor += 2
                guard size > 0, cursor + size <= payload.upperBound else { return }
                keyframe = keyframe || packet[cursor] & 0x1f == 5
                appendNAL(packet[cursor..<(cursor + size)])
                cursor += size
            }
            fragmentOpen = false
        } else if type == 28, payload.count >= 2 {
            let fragment = packet[payload.lowerBound + 1]
            let fragmentType = fragment & 0x1f
            if fragment & 0x80 != 0 {
                appendStartCode()
                access.append((first & 0xe0) | fragmentType)
                keyframe = keyframe || fragmentType == 5
                fragmentOpen = true
            }
            guard fragmentOpen else { return }
            access.append(contentsOf: packet[(payload.lowerBound + 2)..<payload.upperBound])
            if fragment & 0x40 != 0 { fragmentOpen = false }
        }
    }

    private func appendH265(_ packet: [UInt8], _ payload: Range<Int>) {
        guard payload.count >= 2 else { return }
        let first = packet[payload.lowerBound]
        let type = (first >> 1) & 0x3f
        if type < 48 {
            appendNAL(packet[payload])
            keyframe = keyframe || (16...23).contains(type)
            fragmentOpen = false
        } else if type == 48 {
            var cursor = payload.lowerBound + 2
            while cursor + 2 <= payload.upperBound {
                let size = Int(packet[cursor]) << 8 | Int(packet[cursor + 1])
                cursor += 2
                guard size >= 2, cursor + size <= payload.upperBound else { return }
                let nested = (packet[cursor] >> 1) & 0x3f
                keyframe = keyframe || (16...23).contains(nested)
                appendNAL(packet[cursor..<(cursor + size)])
                cursor += size
            }
            fragmentOpen = false
        } else if type == 49, payload.count >= 3 {
            let fragment = packet[payload.lowerBound + 2]
            let fragmentType = fragment & 0x3f
            if fragment & 0x80 != 0 {
                appendStartCode()
                access.append((first & 0x81) | (fragmentType << 1))
                access.append(packet[payload.lowerBound + 1])
                keyframe = keyframe || (16...23).contains(fragmentType)
                fragmentOpen = true
            }
            guard fragmentOpen else { return }
            access.append(contentsOf: packet[(payload.lowerBound + 3)..<payload.upperBound])
            if fragment & 0x40 != 0 { fragmentOpen = false }
        }
    }

    private func appendNAL(_ bytes: ArraySlice<UInt8>) {
        appendStartCode()
        access.append(contentsOf: bytes)
    }

    private func appendStartCode() { access.append(contentsOf: [0, 0, 0, 1]) }

    private func emit() {
        if access.count > 4, let timestamp {
            output(VideoAccessUnit(annexB: access, rtpTimestamp: timestamp, isKeyframe: keyframe, archiveTime: archiveTime))
        }
        access.removeAll(keepingCapacity: true)
        keyframe = false
        fragmentOpen = false
        archiveTime = nil
    }

    private static func payloadRange(_ packet: [UInt8]) -> Range<Int>? {
        guard packet.count >= 12, packet[0] & 0xc0 == 0x80 else { return nil }
        var offset = 12 + Int(packet[0] & 0x0f) * 4
        guard offset <= packet.count else { return nil }
        if packet[0] & 0x10 != 0 {
            guard offset + 4 <= packet.count else { return nil }
            let words = Int(packet[offset + 2]) << 8 | Int(packet[offset + 3])
            offset += 4 + words * 4
        }
        var end = packet.count
        if packet[0] & 0x20 != 0, let padding = packet.last, padding > 0 { end -= Int(padding) }
        guard offset < end else { return nil }
        return offset..<end
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
