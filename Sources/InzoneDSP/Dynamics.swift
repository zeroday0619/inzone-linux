struct ALCParameters {
    var enable: Bool
    var threshold: Float
    var ratio: Float
    var attack: Float
    var release: Float
}

struct DRCParameters {
    var enable: Bool
    var upper: Float
    var lower: Float
    var gate: Float
    var upperRatio: Float
    var upperAttack: Float
    var upperRelease: Float
    var lowerRatio: Float
    var lowerAttack: Float
    var lowerRelease: Float
    var gateRatio: Float
    var gateAttack: Float
    var gateRelease: Float

    @_noLocks
    static func preset(_ mode: Int) -> DRCParameters {
        if mode == 3 {
            return DRCParameters(
                enable: true, upper: -12, lower: -44, gate: -64,
                upperRatio: 2, upperAttack: 0.01, upperRelease: 0.2,
                lowerRatio: 2, lowerAttack: 0.01, lowerRelease: 0.2,
                gateRatio: 3, gateAttack: 0.01, gateRelease: 0.2
            )
        }
        if mode == 2 {
            return DRCParameters(
                enable: true, upper: -15, lower: -35, gate: -50,
                upperRatio: 5, upperAttack: 0.015, upperRelease: 0.05,
                lowerRatio: 5, lowerAttack: 0.005, lowerRelease: 0.1,
                gateRatio: 2.2, gateAttack: 0.03, gateRelease: 0.05
            )
        }
        return DRCParameters(
            enable: mode != 0, upper: -15, lower: -35, gate: -50,
            upperRatio: 2.5, upperAttack: 0.015, upperRelease: 0.05,
            lowerRatio: 2.5, lowerAttack: 0.005, lowerRelease: 0.1,
            gateRatio: 1.9, gateAttack: 0.03, gateRelease: 0.05
        )
    }
}

@_noLocks
private func dynamicsCoefficient(rate: Int, time: Float) -> Float {
    return time == 0 ? 0 : dspExponentialFloat(-1 / (Float(rate) * time))
}

@_noLocks
private func dynamicsEnvelope(previous: Float, sample: Float, decay: Float) -> Float {
    let value = dspAbsoluteFloat(sample)
    return (previous <= value ? 0 : decay) * (previous - value) + value
}

private struct ALCChannel {
    var envelope: Float = 0
    var gain: Float = 1

    @_noLocks
    mutating func process(
        sample: Float, decay: Float, threshold: Float, ratio: Float,
        attack: Float, release: Float
    ) -> Float {
        let currentEnvelope = dynamicsEnvelope(previous: envelope, sample: sample, decay: decay)
        let target: Float = currentEnvelope >= threshold
            ? dspPowerFloat(threshold / currentEnvelope, (ratio - 1) / ratio) : 1
        let currentGain = (gain - target) * (target >= gain ? release : attack) + target
        envelope = currentEnvelope
        gain = currentGain
        return currentGain * sample
    }
}

struct ALCState {
    private var channels: Int = 0
    private var parameters = ALCParameters(enable: false, threshold: 0, ratio: 0, attack: 0, release: 0)
    private var decay: Float = 0
    private var threshold: Float = 0
    private var attack: Float = 0
    private var release: Float = 0
    private var leftChannel = ALCChannel()
    private var rightChannel = ALCChannel()

    @_noLocks
    mutating func configure(channels: Int, rate: Int, parameters: ALCParameters) {
        self.channels = channels
        self.parameters = parameters
        decay = dynamicsCoefficient(rate: rate, time: 0.01)
        threshold = dspPowerFloat(10, parameters.threshold / 20)
        attack = dynamicsCoefficient(rate: rate, time: parameters.attack)
        release = dynamicsCoefficient(rate: rate, time: parameters.release)
        leftChannel = ALCChannel()
        rightChannel = ALCChannel()
    }

    @_noLocks
    mutating func process(left: inout Float, right: inout Float) {
        if !parameters.enable {
            leftChannel = ALCChannel()
            rightChannel = ALCChannel()
            return
        }
        if channels > 0 {
            left = leftChannel.process(
                sample: left, decay: decay, threshold: threshold, ratio: parameters.ratio,
                attack: attack, release: release
            )
        }
        if channels > 1 {
            right = rightChannel.process(
                sample: right, decay: decay, threshold: threshold, ratio: parameters.ratio,
                attack: attack, release: release
            )
        }
    }
}

private struct DRCCoefficients {
    var decay: Float = 0
    var upper: Float = 0
    var lower: Float = 0
    var gate: Float = 0
    var upperAttack: Float = 0
    var upperRelease: Float = 0
    var lowerAttack: Float = 0
    var lowerRelease: Float = 0
    var gateAttack: Float = 0
    var gateRelease: Float = 0
    var gateGain: Float = 0
}

private struct DRCChannel {
    var envelope: Float = 0
    var gain: Float = 0
    var region: Int = 0

    @_noLocks
    mutating func process(sample: Float, parameters: DRCParameters, coefficients: DRCCoefficients) -> Float {
        let currentEnvelope = dynamicsEnvelope(previous: envelope, sample: sample, decay: coefficients.decay)
        var currentRegion = region
        let target: Float
        if currentEnvelope <= coefficients.gate {
            currentRegion = 0
            target = dspPowerFloat(currentEnvelope / coefficients.gate, parameters.gateRatio - 1) * coefficients.gateGain
        } else if currentEnvelope <= coefficients.lower {
            currentRegion = 1
            target = dspPowerFloat(coefficients.lower / currentEnvelope, (parameters.lowerRatio - 1) / parameters.lowerRatio)
        } else if currentEnvelope <= coefficients.upper {
            // The original dynamics implementation retains its previous region in the unity range.
            target = 1
        } else {
            currentRegion = 2
            target = dspPowerFloat(coefficients.upper / currentEnvelope, (parameters.upperRatio - 1) / parameters.upperRatio)
        }
        let previous = gain
        var smoothing: Float = 0
        if currentRegion == 0 || (currentRegion == 1 && previous < 1) {
            smoothing = previous > target ? coefficients.gateRelease : coefficients.gateAttack
        } else if currentRegion == 1 {
            smoothing = previous > target ? coefficients.lowerAttack : coefficients.lowerRelease
        } else if currentRegion == 2 {
            smoothing = previous > target ? coefficients.upperAttack : coefficients.upperRelease
        }
        let currentGain = (previous - target) * smoothing + target
        envelope = currentEnvelope
        gain = currentGain
        region = currentRegion
        return dspMinimumFloat(1, dspMaximumFloat(-1, sample * currentGain))
    }
}

struct DRCState {
    private var channels: Int = 0
    private var parameters = DRCParameters.preset(0)
    private var coefficients = DRCCoefficients()
    private var leftChannel = DRCChannel()
    private var rightChannel = DRCChannel()

    @_noLocks
    mutating func configure(channels: Int, rate: Int, parameters: DRCParameters) {
        self.channels = channels
        self.parameters = parameters
        coefficients.decay = dynamicsCoefficient(rate: rate, time: 0.01)
        coefficients.upper = dspPowerFloat(10, parameters.upper / 20)
        coefficients.lower = dspMinimumFloat(coefficients.upper, dspPowerFloat(10, parameters.lower / 20))
        coefficients.gate = dspMinimumFloat(coefficients.lower, dspPowerFloat(10, parameters.gate / 20))
        coefficients.upperAttack = dynamicsCoefficient(rate: rate, time: parameters.upperAttack)
        coefficients.upperRelease = dynamicsCoefficient(rate: rate, time: parameters.upperRelease)
        coefficients.lowerAttack = dynamicsCoefficient(rate: rate, time: parameters.lowerAttack)
        coefficients.lowerRelease = dynamicsCoefficient(rate: rate, time: parameters.lowerRelease)
        coefficients.gateAttack = dynamicsCoefficient(rate: rate, time: parameters.gateAttack)
        coefficients.gateRelease = dynamicsCoefficient(rate: rate, time: parameters.gateRelease)
        coefficients.gateGain = dspPowerFloat(
            coefficients.lower / coefficients.gate, (parameters.lowerRatio - 1) / parameters.lowerRatio
        )
        leftChannel = DRCChannel()
        rightChannel = DRCChannel()
    }

    @_noLocks
    mutating func process(left: inout Float, right: inout Float) {
        if !parameters.enable {
            leftChannel = DRCChannel()
            rightChannel = DRCChannel()
            return
        }
        if channels > 0 {
            left = leftChannel.process(sample: left, parameters: parameters, coefficients: coefficients)
        }
        if channels > 1 {
            right = rightChannel.process(sample: right, parameters: parameters, coefficients: coefficients)
        }
    }
}
