/// The detector preserves the recovered eight-frame cadence and 24-frame lookahead.
struct SpatialALCState {
    private var peak: Double = 0
    private var gain: Double = 1
    private var history = InlineArray<48, Double>(repeating: 0)

    init() {}

    @_noLocks
    mutating func reset(boost: Int) {
        peak = 0
        gain = dspPower(10.0, Double(boost) / 20.0)
        for index in 0..<48 {
            history[index] = 0
        }
    }

    @_noLocks
    mutating func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>) {
        var current = InlineArray<16, Double>(repeating: 0)
        var currentPeak: Double = 0
        let minimumNormal = Double(Float.leastNormalMagnitude)
        for index in 0..<16 {
            var sample = Double(input[index]) * gain
            if Swift.abs(sample) < minimumNormal {
                sample = 0
            }
            current[index] = sample
            if Swift.abs(sample) > currentPeak {
                currentPeak = Swift.abs(sample)
            }
        }

        let change = currentPeak - peak
        if change > 0 {
            peak += change * (Double(0x67d2ec9b) * 0x1p-31)
        } else {
            peak *= Double(0x7ac6b85a) * 0x1p-31
        }
        let logarithmicPeak = Self.logarithmDividedByEight(peak)
        let currentGain = logarithmicPeak > 0 ? dspExponential(-logarithmicPeak * 8) : 1.0
        for index in 0..<16 {
            var sample = dspMinimum(1.0, dspMaximum(-1.0, history[index] * currentGain))
            if Swift.abs(sample) < minimumNormal {
                sample = 0
            }
            output[index] = Float(sample)
        }

        for index in 0..<32 {
            history[index] = history[index + 16]
        }
        for index in 0..<16 {
            history[index + 32] = current[index]
        }
    }

    @_noLocks
    private static func logarithmDividedByEight(_ input: Double) -> Double {
        var value = input
        var positiveShifts = 0
        while value >= 1.0 {
            value *= 0.5
            positiveShifts += 1
        }

        let wide = Int64(value * 2_147_483_648.0)
        var quantized = Int32(clamping: wide)
        var shift = 0
        while quantized < 0x40000000 && shift < 11 {
            quantized = Int32(bitPattern: UInt32(bitPattern: quantized) &* 2)
            shift += 1
        }
        if shift == 11 {
            quantized = Int32.max
        }

        // Q31 intermediates retain the original signed truncation and unsigned wraparound.
        let shifted = Int64(Int32(bitPattern: UInt32(bitPattern: quantized) &+ 0x80000000))
        let square = Int64(Int32(truncatingIfNeeded: (shifted * shifted) >> 31))
        let cube = Int64(Int32(truncatingIfNeeded: (square * shifted) >> 31))
        let polynomial = ((cube * 0x2aaaaaaa) >> 31) - (square >> 1) + shifted
        let result = Int32(bitPattern:
            UInt32(truncatingIfNeeded: polynomial >> 3)
                &+ UInt32(bitPattern: logarithmOffset(shift)))
        return Double(result) * 0x1p-31 + Double(positiveShifts) * 0.08664339756999312
    }

    @_noLocks
    private static func logarithmOffset(_ shift: Int) -> Int32 {
        // A switch keeps the fixed table free of lazy initialization in the audio callback.
        switch shift {
        case 0: return 0
        case 1: return -186_064_426
        case 2: return -372_130_999
        case 3: return -558_195_425
        case 4: return -744_261_998
        case 5: return -930_326_424
        case 6: return -1_116_390_849
        case 7: return -1_302_457_422
        case 8: return -1_488_521_848
        case 9: return -1_674_588_421
        case 10: return -1_860_652_847
        default: return -2_046_717_273
        }
    }
}
