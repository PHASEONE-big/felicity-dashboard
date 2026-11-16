import Foundation

/*
 ITU G.722 64 kbit/s codec, ported from this repository's Android G722Encoder
 and G722Decoder. Those adapt AOSP embdrv/g722, originally by Steve Underwood
 (public domain), based partly on CMU Speech Group code (1993).
 */
private enum G722Tables {
    static let q6 = [0,35,72,110,150,190,233,276,323,370,422,473,530,587,650,714,786,858,940,1023,1121,1219,1339,1458,1612,1765,1980,2195,2557,2919,0,0]
    static let iln = [0,63,62,31,30,29,28,27,26,25,24,23,22,21,20,19,18,17,16,15,14,13,12,11,10,9,8,7,6,5,4,0]
    static let ilp = [0,61,60,59,58,57,56,55,54,53,52,51,50,49,48,47,46,45,44,43,42,41,40,39,38,37,36,35,34,33,32,0]
    static let wl = [-60,-30,58,172,334,538,1198,3042]
    static let rl42 = [0,7,6,5,4,3,2,1,7,6,5,4,3,2,1,0]
    static let ilb = [2048,2093,2139,2186,2233,2282,2332,2383,2435,2489,2543,2599,2656,2714,2774,2834,2896,2960,3025,3091,3158,3228,3298,3371,3444,3520,3597,3676,3756,3838,3922,4008]
    static let qm4 = [0,-20456,-12896,-8968,-6288,-4240,-2584,-1200,20456,12896,8968,6288,4240,2584,1200,0]
    static let qm2 = [-7408,-1616,7408,1616]
    static let qmf = [3,-11,12,32,-210,951,3876,-805,362,-156,53,-11]
    static let qmfOdd = [-11,53,-156,362,-805,3876,951,-210,32,12,-11,3]
    static let ihn = [0,1,0], ihp = [0,3,2], wh = [0,-214,798], rh2 = [2,1,2,1]
    static let qm6 = [-136,-136,-136,-136,-24808,-21904,-19008,-16704,-14984,-13512,-12280,-11192,-10232,-9360,-8576,-7856,-7192,-6576,-6000,-5456,-4944,-4464,-4008,-3576,-3168,-2776,-2400,-2032,-1688,-1360,-1040,-728,24808,21904,19008,16704,14984,13512,12280,11192,10232,9360,8576,7856,7192,6576,6000,5456,4944,4464,4008,3576,3168,2776,2400,2032,1688,1360,1040,728,432,136,-432,-136]
    static func sat(_ value: Int) -> Int { min(32767, max(-32768, value)) }
}

private final class G722Band {
    var s = 0, sp = 0, sz = 0, nb = 0, det: Int
    var r = [Int](repeating: 0, count: 3), a = [Int](repeating: 0, count: 3), ap = [Int](repeating: 0, count: 3), p = [Int](repeating: 0, count: 3)
    var d = [Int](repeating: 0, count: 7), b = [Int](repeating: 0, count: 7), bp = [Int](repeating: 0, count: 7)
    init(det: Int) { self.det = det }
    func update(_ value: Int) {
        d[0] = value; r[0] = G722Tables.sat(s + value); p[0] = G722Tables.sat(sz + value)
        let sg0 = p[0] >> 15, sg1 = p[1] >> 15, sg2 = p[2] >> 15
        var wd1 = G722Tables.sat(a[1] << 2)
        var wd2 = sg0 == sg1 ? -wd1 : wd1
        wd2 = min(32767, wd2)
        ap[2] = min(12288, max(-12288, (wd2 >> 7) + (sg0 == sg2 ? 128 : -128) + ((a[2] * 32512) >> 15)))
        wd1 = sg0 == sg1 ? 192 : -192; wd2 = (a[1] * 32640) >> 15
        let ap1 = G722Tables.sat(wd1 + wd2)
        var wd3 = G722Tables.sat(15360 - ap[2])
        ap[1] = min(wd3, max(-wd3, ap1))
        wd1 = value == 0 ? 0 : 128
        for i in 1..<7 {
            wd2 = (d[i] >> 15) == (value >> 15) ? wd1 : -wd1
            wd3 = (b[i] * 32640) >> 15; bp[i] = G722Tables.sat(wd2 + wd3)
        }
        var sum = 0
        for i in stride(from: 6, through: 1, by: -1) {
            d[i] = d[i - 1]; b[i] = bp[i]; wd1 = G722Tables.sat(d[i] + d[i]); sum += (b[i] * wd1) >> 15
        }
        sz = G722Tables.sat(sum)
        for i in stride(from: 2, through: 1, by: -1) { r[i] = r[i - 1]; p[i] = p[i - 1]; a[i] = ap[i] }
        wd1 = (a[1] * G722Tables.sat(r[1] + r[1])) >> 15
        wd2 = (a[2] * G722Tables.sat(r[2] + r[2])) >> 15
        sp = G722Tables.sat(wd1 + wd2); s = G722Tables.sat(sp + sz)
    }
    func adapt(index: Int, high: Bool) {
        nb = min(high ? 22528 : 18432, max(0, ((nb * 127) >> 7) + (high ? G722Tables.wh[G722Tables.rh2[index]] : G722Tables.wl[G722Tables.rl42[index]])))
        let wd1 = (nb >> 6) & 31, wd2 = (high ? 10 : 8) - (nb >> 11)
        det = (wd2 < 0 ? G722Tables.ilb[wd1] << -wd2 : G722Tables.ilb[wd1] >> wd2) << 2
    }
}

final class DoorbellG722Encoder {
    private let low = G722Band(det: 32), high = G722Band(det: 8)
    private var x = [Int](repeating: 0, count: 24)
    /// Two 16 kHz PCM samples produce one RTP G.722 octet (8 kHz RTP clock).
    func encode(_ pcm: [Int16]) -> Data {
        var result = Data(); result.reserveCapacity(pcm.count / 2)
        for j in stride(from: 0, to: pcm.count - pcm.count % 2, by: 2) {
            for i in 0..<22 { x[i] = x[i + 2] }; x[22] = Int(pcm[j]); x[23] = Int(pcm[j + 1])
            var even = 0, odd = 0
            for i in 0..<12 { odd += x[2 * i] * G722Tables.qmf[i]; even += x[2 * i + 1] * G722Tables.qmf[11 - i] }
            let lowValue = (even + odd) >> 14, highValue = (even - odd) >> 14
            var error = G722Tables.sat(lowValue - low.s), magnitude = error >= 0 ? error : -(error + 1)
            var index = 1
            while index < 30 && magnitude >= ((G722Tables.q6[index] * low.det) >> 12) { index += 1 }
            let lowCode = error < 0 ? G722Tables.iln[index] : G722Tables.ilp[index], ril = lowCode >> 2
            let lowDelta = (low.det * G722Tables.qm4[ril]) >> 15
            low.adapt(index: ril, high: false); low.update(lowDelta)
            error = G722Tables.sat(highValue - high.s); magnitude = error >= 0 ? error : -(error + 1)
            let mih = magnitude >= ((564 * high.det) >> 12) ? 2 : 1
            let highCode = error < 0 ? G722Tables.ihn[mih] : G722Tables.ihp[mih]
            let highDelta = (high.det * G722Tables.qm2[highCode]) >> 15
            high.adapt(index: highCode, high: true); high.update(highDelta)
            result.append(UInt8((highCode << 6) | lowCode))
        }
        return result
    }
}

final class DoorbellG722Decoder {
    private let low = G722Band(det: 32), high = G722Band(det: 8)
    private var x = [Int](repeating: 0, count: 24)
    func decode(_ encoded: Data) -> [Int16] {
        var pcm: [Int16] = []; pcm.reserveCapacity(encoded.count * 2)
        for byte in encoded {
            let code = Int(byte), lowCode = (code & 63) >> 2, highCode = (code >> 6) & 3
            let rlow = min(16383, max(-16384, low.s + ((low.det * G722Tables.qm6[code & 63]) >> 15)))
            let lowDelta = (low.det * G722Tables.qm4[lowCode]) >> 15
            low.adapt(index: lowCode, high: false); low.update(lowDelta)
            let highDelta = (high.det * G722Tables.qm2[highCode]) >> 15
            let rhigh = min(16383, max(-16384, high.s + highDelta))
            high.adapt(index: highCode, high: true); high.update(highDelta)
            for i in 0..<22 { x[i] = x[i + 2] }; x[22] = rlow + rhigh; x[23] = rlow - rhigh
            var out1 = 0, out2 = 0
            for i in 0..<12 { out2 += x[2 * i] * G722Tables.qmf[i]; out1 += x[2 * i + 1] * G722Tables.qmfOdd[i] }
            pcm.append(Int16(G722Tables.sat(out1 >> 11))); pcm.append(Int16(G722Tables.sat(out2 >> 11)))
        }
        return pcm
    }
}
