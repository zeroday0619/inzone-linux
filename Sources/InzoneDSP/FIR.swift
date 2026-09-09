import CLADSPA

enum FIRBank: Int {
    case standard, personal, downmix
}

struct FIRState {
    private static let channels = 8
    private static let taps = 512
    private static let ears = 2
    private static let coefficientCount = channels * taps * ears
    private static let historyCount = channels * taps
    private static let denormalThreshold = Float(bitPattern: 0x2f80_0000)

    private var bank: FIRBank = .standard
    private var coefficients: UnsafeMutablePointer<Float>?
    private var history: UnsafeMutablePointer<Float>?
    private var position = 0

    mutating func initialize(bank: FIRBank) -> Bool {
        release()
        guard let coefficients = calloc(Self.coefficientCount, MemoryLayout<Float>.stride) else { return false }
        guard let history = calloc(Self.historyCount, MemoryLayout<Float>.stride) else {
            free(coefficients)
            return false
        }
        self.bank = bank
        self.coefficients = coefficients.bindMemory(to: Float.self, capacity: Self.coefficientCount)
        self.history = history.bindMemory(to: Float.self, capacity: Self.historyCount)
        guard loadCoefficientBank() else {
            release()
            return false
        }
        reset()
        return true
    }

    mutating func release() {
        if let coefficients { free(coefficients) }
        if let history { free(history) }
        coefficients = nil
        history = nil
        position = 0
    }

    @_noLocks
    mutating func reset() {
        guard let history else { return }
        for index in 0..<Self.historyCount { history[index] = 0 }
        position = 0
    }

    @_noLocks
    mutating func process(inputs: InlineArray<8, Float>) -> (left: Float, right: Float) {
        guard let coefficients, let history else { return (0, 0) }
        var samples = inputs
        for index in 0..<Self.channels {
            let sample = samples[index]
            if dspAbsoluteFloat(sample) < Self.denormalThreshold {
                samples[index] = 0
            }
        }

        position = (position + Self.taps - 1) & (Self.taps - 1)
        // Sony's internal channel order is FC, FL, FR, SL, SR, RL, RR, LFE.
        history[0 * Self.taps + position] = samples[2]
        history[1 * Self.taps + position] = samples[0]
        history[2 * Self.taps + position] = samples[1]
        history[3 * Self.taps + position] = samples[6]
        history[4 * Self.taps + position] = samples[7]
        history[5 * Self.taps + position] = samples[4]
        history[6 * Self.taps + position] = samples[5]
        history[7 * Self.taps + position] = samples[3]

        var outputs: InlineArray<2, Float> = .init(repeating: 0)
        for ear in 0..<Self.ears {
            var accumulator: Float = 0
            for base in stride(from: 0, to: Self.taps, by: 8) {
                let laneZero = products(
                    tap: base, ear: ear, coefficients: coefficients, history: history
                )
                let first = (laneZero[0] + laneZero[1]) + (laneZero[2] + laneZero[3])
                let second = (laneZero[4] + laneZero[5]) + (laneZero[6] + laneZero[7])
                accumulator = (first + second) + accumulator

                for lane in 1..<8 {
                    let values = products(
                        tap: base + lane, ear: ear, coefficients: coefficients, history: history
                    )
                    accumulator += values[7]
                    accumulator += values[6]
                    accumulator += lane == 2 || lane == 7
                        ? values[5] + values[4] : values[4] + values[5]
                    let firstPair = values[0] + values[1]
                    let secondPair = values[2] + values[3]
                    accumulator += lane == 1 || lane == 3 || lane == 6
                        ? firstPair + secondPair : secondPair + firstPair
                }
            }
            outputs[ear] = accumulator
        }
        return (outputs[0], outputs[1])
    }

    @inline(__always) @_noLocks
    private func products(
        tap: Int, ear: Int, coefficients: UnsafeMutablePointer<Float>, history: UnsafeMutablePointer<Float>
    ) -> InlineArray<8, Float> {
        let historyIndex = (position + tap) & (Self.taps - 1)
        var result: InlineArray<8, Float> = .init(repeating: 0)
        for channel in 0..<Self.channels {
            result[channel] = history[channel * Self.taps + historyIndex]
                * coefficients[(ear * Self.channels + channel) * Self.taps + tap]
        }
        return result
    }

    private mutating func loadCoefficientBank() -> Bool {
        guard coefficients != nil else { return false }
        if inzone_dsp_getenv(dspStaticCString("INZONE_DSP_DATA_DIR")) != nil {
            return loadCoefficientBank(root: .explicit)
        }
        return loadCoefficientBank(root: .home)
    }

    private enum CoefficientRoot {
        case explicit
        case home
    }

    private mutating func loadCoefficientBank(root: CoefficientRoot) -> Bool {
        guard let coefficients else { return false }
        return withCoefficientRoot(root: root) { path in
            let directory = inzone_dsp_open(path, Int32(INZONE_DSP_DIRECTORY_FLAGS))
            guard directory >= 0 else { return false }
            defer { _ = inzone_dsp_close(directory) }

            var manifest: InlineArray<264, UInt8> = .init(repeating: 0)
            let manifestLoaded = withUnsafeMutablePointer(to: &manifest) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: 264) {
                    readRegularFile(directory: directory, name: dspStaticCString("fir-bank.bin"),
                                    destination: $0, count: 264)
                }
            }
            guard manifestLoaded, manifest[0] == 0x49, manifest[1] == 0x5a,
                  manifest[2] == 0x46, manifest[3] == 0x42,
                  unsigned32(manifest, 4) == 1 else { return false }

            for publicChannel in 0..<Self.channels {
                var wave: InlineArray<4152, UInt8> = .init(repeating: 0)
                let loaded = withUnsafeMutablePointer(to: &wave) { pointer in
                    pointer.withMemoryRebound(to: UInt8.self, capacity: 4152) { bytes in
                        guard readRegularFile(directory: directory, name: channelFilename(publicChannel),
                                              destination: bytes, count: 4152),
                              validWaveHeader(bytes) else { return false }
                        let digest = dspSHA256(bytes, count: 4152)
                        for index in 0..<32 where digest[index] != manifest[8 + publicChannel * 32 + index] {
                            return false
                        }
                        return loadWave(bytes: bytes, publicChannel: publicChannel, coefficients: coefficients)
                    }
                }
                guard loaded else { return false }
            }
            return bank != .downmix || validateDownmix(coefficients)
        }
    }

    private func withCoefficientRoot(
        root: CoefficientRoot, _ body: (UnsafePointer<CChar>) -> Bool
    ) -> Bool {
        var path: InlineArray<4096, CChar> = .init(repeating: 0)
        return withUnsafeMutablePointer(to: &path) { storage in
            storage.withMemoryRebound(to: CChar.self, capacity: 4096) { destination in
                var position = 0
                switch root {
                case .explicit:
                    guard let dataRoot = inzone_dsp_getenv(dspStaticCString("INZONE_DSP_DATA_DIR")),
                          appendCString(UnsafePointer(dataRoot), to: destination, position: &position) else {
                        return false
                    }
                case .home:
                    guard let home = inzone_dsp_getenv(dspStaticCString("HOME")),
                          appendCString(UnsafePointer(home), to: destination, position: &position) else { return false }
                }
                guard appendCString(rootSuffix(root: root), to: destination, position: &position) else { return false }
                destination[position] = 0
                return body(UnsafePointer(destination))
            }
        }
    }

    private func rootSuffix(root: CoefficientRoot) -> UnsafePointer<CChar> {
        switch (bank, root) {
        case (.standard, .home): return dspStaticCString("/.local/share/inzone-linux/assets")
        case (.standard, .explicit): return dspStaticCString("/assets")
        case (.personal, .home): return dspStaticCString("/.local/share/inzone-linux/personal")
        case (.personal, .explicit): return dspStaticCString("/personal")
        case (.downmix, .home): return dspStaticCString("/.local/share/inzone-linux/assets/downmix")
        case (.downmix, .explicit): return dspStaticCString("/assets/downmix")
        }
    }

    private func channelFilename(_ publicChannel: Int) -> UnsafePointer<CChar> {
        switch publicChannel {
        case 0: return dspStaticCString("FL.wav")
        case 1: return dspStaticCString("FR.wav")
        case 2: return dspStaticCString("FC.wav")
        case 3: return dspStaticCString("LFE.wav")
        case 4: return dspStaticCString("RL.wav")
        case 5: return dspStaticCString("RR.wav")
        case 6: return dspStaticCString("SL.wav")
        default: return dspStaticCString("SR.wav")
        }
    }

    private func appendCString(
        _ source: UnsafePointer<CChar>, to destination: UnsafeMutablePointer<CChar>, position: inout Int
    ) -> Bool {
        var source = source
        while source.pointee != 0 {
            guard position < 4095 else { return false }
            destination[position] = source.pointee
            position += 1
            source += 1
        }
        return true
    }

    private func loadWave(
        bytes: UnsafePointer<UInt8>, publicChannel: Int, coefficients: UnsafeMutablePointer<Float>
    ) -> Bool {
        let internalChannel: Int
        switch publicChannel {
        case 0: internalChannel = 1
        case 1: internalChannel = 2
        case 2: internalChannel = 0
        case 3: internalChannel = 7
        case 4: internalChannel = 5
        case 5: internalChannel = 6
        case 6: internalChannel = 3
        default: internalChannel = 4
        }
        for tap in 0..<Self.taps {
            let offset = 56 + tap * 8
            let left = Float(bitPattern: unsigned32(bytes, offset))
            let right = Float(bitPattern: unsigned32(bytes, offset + 4))
            guard left.isFinite, right.isFinite else { return false }
            coefficients[(0 * Self.channels + internalChannel) * Self.taps + tap] = left
            coefficients[(1 * Self.channels + internalChannel) * Self.taps + tap] = right
        }
        return true
    }

    private func readRegularFile(
        directory: Int32, name: UnsafePointer<CChar>, destination: UnsafeMutablePointer<UInt8>, count: Int
    ) -> Bool {
        let file = inzone_dsp_openat(directory, name, Int32(INZONE_DSP_FILE_FLAGS))
        guard file >= 0 else { return false }
        defer { _ = inzone_dsp_close(file) }
        var status = stat()
        guard inzone_dsp_fstat(file, &status) == 0,
              (status.st_mode & UInt32(INZONE_DSP_FILE_TYPE_MASK)) == UInt32(INZONE_DSP_REGULAR_FILE),
              status.st_size == count else { return false }
        var offset = 0
        while offset < count {
            let result = inzone_dsp_read(file, destination + offset, count - offset)
            if result > 0 {
                offset += result
            } else if result < 0, inzone_dsp_errno_location().pointee == INZONE_DSP_INTERRUPTED {
                continue
            } else {
                return false
            }
        }
        return true
    }

    private func validWaveHeader(_ header: UnsafePointer<UInt8>) -> Bool {
        return header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46
            && unsigned32(header, 4) == 4144
            && header[8] == 0x57 && header[9] == 0x41 && header[10] == 0x56 && header[11] == 0x45
            && header[12] == 0x66 && header[13] == 0x6d && header[14] == 0x74 && header[15] == 0x20
            && unsigned32(header, 16) == 16 && unsigned16(header, 20) == 3 && unsigned16(header, 22) == 2
            && unsigned32(header, 24) == 48_000 && unsigned32(header, 28) == 384_000
            && unsigned16(header, 32) == 8 && unsigned16(header, 34) == 32
            && header[36] == 0x66 && header[37] == 0x61 && header[38] == 0x63 && header[39] == 0x74
            && unsigned32(header, 40) == 4 && unsigned32(header, 44) == 512
            && header[48] == 0x64 && header[49] == 0x61 && header[50] == 0x74 && header[51] == 0x61
            && unsigned32(header, 52) == 4096
    }

    private func unsigned16(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func unsigned32(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private func unsigned32(_ bytes: InlineArray<264, UInt8>, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private func validateDownmix(_ coefficients: UnsafeMutablePointer<Float>) -> Bool {
        let gain = Float(bitPattern: 0x3f35_04f3)
        for ear in 0..<Self.ears {
            for channel in 0..<Self.channels {
                let expected: Float
                switch (ear, channel) {
                case (_, 0): expected = gain
                case (0, 1): expected = 1
                case (1, 2): expected = 1
                case (0, 3), (1, 4), (0, 5), (1, 6): expected = gain
                default: expected = 0
                }
                let base = (ear * Self.channels + channel) * Self.taps
                guard coefficients[base].bitPattern == expected.bitPattern else { return false }
                for tap in 1..<Self.taps where coefficients[base + tap].bitPattern != 0 { return false }
            }
        }
        return true
    }
}

private func dspStaticCString(_ value: StaticString) -> UnsafePointer<CChar> {
    UnsafeRawPointer(value.utf8Start).assumingMemoryBound(to: CChar.self)
}

private let dspSHA256Constants: [UInt32] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]

private func dspSHA256(_ bytes: UnsafePointer<UInt8>, count: Int) -> InlineArray<32, UInt8> {
    var state: InlineArray<8, UInt32> = .init(repeating: 0)
    state[0] = 0x6a09e667
    state[1] = 0xbb67ae85
    state[2] = 0x3c6ef372
    state[3] = 0xa54ff53a
    state[4] = 0x510e527f
    state[5] = 0x9b05688c
    state[6] = 0x1f83d9ab
    state[7] = 0x5be0cd19

    var offset = 0
    while offset + 64 <= count {
        dspSHA256Block(bytes + offset, state: &state)
        offset += 64
    }
    let remainder = count - offset
    var tail: InlineArray<128, UInt8> = .init(repeating: 0)
    for index in 0..<remainder { tail[index] = bytes[offset + index] }
    tail[remainder] = 0x80
    let tailCount = remainder < 56 ? 64 : 128
    let bitCount = UInt64(count) &* 8
    for index in 0..<8 {
        tail[tailCount - 1 - index] = UInt8(truncatingIfNeeded: bitCount >> (index * 8))
    }
    withUnsafePointer(to: &tail) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: 128) { data in
            dspSHA256Block(data, state: &state)
            if tailCount == 128 { dspSHA256Block(data + 64, state: &state) }
        }
    }

    var digest: InlineArray<32, UInt8> = .init(repeating: 0)
    for index in 0..<8 {
        let value = state[index]
        digest[index * 4] = UInt8(truncatingIfNeeded: value >> 24)
        digest[index * 4 + 1] = UInt8(truncatingIfNeeded: value >> 16)
        digest[index * 4 + 2] = UInt8(truncatingIfNeeded: value >> 8)
        digest[index * 4 + 3] = UInt8(truncatingIfNeeded: value)
    }
    return digest
}

private func dspSHA256Block(_ block: UnsafePointer<UInt8>, state: inout InlineArray<8, UInt32>) {
    var schedule: InlineArray<64, UInt32> = .init(repeating: 0)
    for index in 0..<16 {
        let offset = index * 4
        schedule[index] = UInt32(block[offset]) << 24 | UInt32(block[offset + 1]) << 16
            | UInt32(block[offset + 2]) << 8 | UInt32(block[offset + 3])
    }
    for index in 16..<64 {
        let first = dspRotateRight(schedule[index - 15], 7) ^ dspRotateRight(schedule[index - 15], 18)
            ^ (schedule[index - 15] >> 3)
        let second = dspRotateRight(schedule[index - 2], 17) ^ dspRotateRight(schedule[index - 2], 19)
            ^ (schedule[index - 2] >> 10)
        schedule[index] = schedule[index - 16] &+ first &+ schedule[index - 7] &+ second
    }

    var a = state[0]
    var b = state[1]
    var c = state[2]
    var d = state[3]
    var e = state[4]
    var f = state[5]
    var g = state[6]
    var h = state[7]
    for index in 0..<64 {
        let first = dspRotateRight(e, 6) ^ dspRotateRight(e, 11) ^ dspRotateRight(e, 25)
        let choice = (e & f) ^ (~e & g)
        let temporaryOne = h &+ first &+ choice &+ dspSHA256Constants[index] &+ schedule[index]
        let second = dspRotateRight(a, 2) ^ dspRotateRight(a, 13) ^ dspRotateRight(a, 22)
        let majority = (a & b) ^ (a & c) ^ (b & c)
        let temporaryTwo = second &+ majority
        h = g
        g = f
        f = e
        e = d &+ temporaryOne
        d = c
        c = b
        b = a
        a = temporaryOne &+ temporaryTwo
    }
    state[0] &+= a
    state[1] &+= b
    state[2] &+= c
    state[3] &+= d
    state[4] &+= e
    state[5] &+= f
    state[6] &+= g
    state[7] &+= h
}

@inline(__always)
private func dspRotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
    (value >> count) | (value << (32 - count))
}
