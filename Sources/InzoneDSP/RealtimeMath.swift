import CLADSPA

// Explicit C declarations keep the existing libm contract at one auditable boundary.
@inline(__always) @_noLocks
func dspExponentialFloat(_ value: Float) -> Float { inzone_dsp_expf(value) }

@inline(__always) @_noLocks
func dspPowerFloat(_ base: Float, _ exponent: Float) -> Float { inzone_dsp_powf(base, exponent) }

@inline(__always) @_noLocks
func dspAbsoluteFloat(_ value: Float) -> Float { inzone_dsp_fabsf(value) }

@inline(__always) @_noLocks
func dspMinimumFloat(_ left: Float, _ right: Float) -> Float { inzone_dsp_fminf(left, right) }

@inline(__always) @_noLocks
func dspMaximumFloat(_ left: Float, _ right: Float) -> Float { inzone_dsp_fmaxf(left, right) }

@inline(__always) @_noLocks
func dspRoundFloat(_ value: Float) -> Float { inzone_dsp_roundf(value) }

@inline(__always) @_noLocks
func dspExponential(_ value: Double) -> Double { inzone_dsp_exp(value) }

@inline(__always) @_noLocks
func dspPower(_ base: Double, _ exponent: Double) -> Double { inzone_dsp_pow(base, exponent) }

@inline(__always) @_noLocks
func dspMinimum(_ left: Double, _ right: Double) -> Double { inzone_dsp_fmin(left, right) }

@inline(__always) @_noLocks
func dspMaximum(_ left: Double, _ right: Double) -> Double { inzone_dsp_fmax(left, right) }
