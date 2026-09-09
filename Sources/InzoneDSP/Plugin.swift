import CLADSPA

private enum PluginKind: Int {
    case spatial, dynamicRange, automaticLevel, microphone, biquad, equalizerBiquad
    case firStandard, firPersonal, firDownmix

    var firBank: FIRBank? {
        switch self {
        case .firStandard: return .standard
        case .firPersonal: return .personal
        case .firDownmix: return .downmix
        default: return nil
        }
    }
}

private struct PluginState {
    var kind: PluginKind = .spatial
    var rate = 48_000
    var position = 0
    var ports: InlineArray<11, UnsafeMutablePointer<Float>?> = .init(repeating: nil)
    var controls: InlineArray<5, Float> = .init(repeating: 0)
    var block: InlineArray<16, Float> = .init(repeating: 0)
    var ready: InlineArray<16, Float> = .init(repeating: 0)
    var history: InlineArray<4, Double> = .init(repeating: 0)
    var spatial = SpatialALCState()
    var dynamicRange = DRCState()
    var automaticLevel = ALCState()
    var fir = FIRState()

    @_noLocks
    func control(_ port: Int, fallback: Float, lower: Float, upper: Float) -> Float {
        let value = ports[port]?.pointee ?? fallback
        return value.isFinite ? dspMaximumFloat(lower, dspMinimumFloat(upper, value)) : fallback
    }

    @_noLocks
    mutating func configure(force: Bool) {
        var next: InlineArray<5, Float> = .init(repeating: 0)
        switch kind {
        case .firStandard, .firPersonal, .firDownmix:
            break
        case .spatial:
            next[0] = dspRoundFloat(control(4, fallback: 1, lower: 0, upper: 1))
        case .dynamicRange:
            next[0] = dspRoundFloat(control(4, fallback: 0, lower: 0, upper: 2))
        case .microphone:
            next[0] = dspRoundFloat(control(2, fallback: 1, lower: 0, upper: 1))
        case .biquad, .equalizerBiquad:
            for index in 0..<5 {
                next[index] = control(index + 2, fallback: index == 0 ? 1 : 0, lower: -64, upper: 64)
            }
        case .automaticLevel:
            next[0] = dspRoundFloat(control(4, fallback: 1, lower: 0, upper: 1))
            next[1] = control(5, fallback: -18, lower: -60, upper: 0)
            next[2] = control(6, fallback: 1_000, lower: 1, upper: 1_000)
            next[3] = control(7, fallback: 0.001, lower: 0.0001, upper: 2)
            next[4] = control(8, fallback: 1, lower: 0.0001, upper: 10)
        }

        // Bitwise comparison preserves resets caused by signed-zero control changes.
        var unchanged = true
        for index in 0..<5 where next[index].bitPattern != controls[index].bitPattern {
            unchanged = false
        }
        if !force && unchanged { return }
        controls = next

        switch kind {
        case .firStandard, .firPersonal, .firDownmix:
            fir.reset()
        case .spatial:
            spatial.reset(boost: Int(next[0]))
            position = 0
            block = .init(repeating: 0)
            ready = .init(repeating: 0)
        case .biquad, .equalizerBiquad:
            history = .init(repeating: 0)
        case .automaticLevel:
            automaticLevel.configure(
                channels: 2, rate: rate,
                parameters: ALCParameters(enable: next[0] != 0, threshold: next[1],
                                          ratio: next[2], attack: next[3], release: next[4])
            )
        case .dynamicRange, .microphone:
            let mode = kind == .microphone ? (next[0] != 0 ? 3 : 0) : Int(next[0])
            dynamicRange.configure(channels: kind == .microphone ? 1 : 2, rate: rate,
                                   parameters: DRCParameters.preset(mode))
        }
    }

    @_noLocks
    mutating func processBiquad(_ sample: Float) -> Float {
        let output: Double
        if kind == .equalizerBiquad {
            // Each assignment retains the single-precision rounding of the user EQ.
            var value = controls[0] * sample + controls[1] * Float(history[0])
            value += controls[2] * Float(history[1])
            value -= controls[3] * Float(history[2])
            value -= controls[4] * Float(history[3])
            output = Double(value)
        } else {
            // The model filter evaluates its feed-forward terms in this exact order.
            var value = Double(controls[1]) * history[0] + Double(controls[2]) * history[1]
            value += Double(controls[0]) * Double(sample)
            value -= Double(controls[4]) * history[3]
            value -= Double(controls[3]) * history[2]
            output = value
        }
        let result = Float(output)
        guard output.isFinite, result.isFinite else {
            history = .init(repeating: 0)
            return 0
        }
        history[1] = history[0]
        history[0] = Double(sample)
        history[3] = history[2]
        history[2] = output
        return result
    }

    @_noLocks
    mutating func processSpatial(left: inout Float, right: inout Float) {
        let offset = 2 * position
        block[offset] = left
        block[offset + 1] = right
        left = ready[offset]
        right = ready[offset + 1]
        position += 1
        if position == 8 {
            withUnsafePointer(to: &block) { input in
                input.withMemoryRebound(to: Float.self, capacity: 16) { samples in
                    withUnsafeMutablePointer(to: &ready) { output in
                        output.withMemoryRebound(to: Float.self, capacity: 16) { result in
                            spatial.process(input: samples, output: result)
                        }
                    }
                }
            }
            position = 0
        }
    }
}

@c(inzone_dsp_instantiate)
private func instantiate(_ descriptor: UnsafePointer<LADSPA_Descriptor>?,
                         _ rate: CUnsignedLong) -> LADSPA_Handle? {
    guard rate == 48_000, let descriptor,
          let kind = PluginKind(rawValue: Int(bitPattern: descriptor.pointee.ImplementationData)),
          let memory = calloc(1, MemoryLayout<PluginState>.stride) else { return nil }
    let state = memory.bindMemory(to: PluginState.self, capacity: 1)
    state.initialize(to: PluginState())
    state.pointee.kind = kind
    state.pointee.rate = Int(rate)
    if let bank = kind.firBank, !state.pointee.fir.initialize(bank: bank) {
        state.deinitialize(count: 1)
        free(memory)
        return nil
    }
    state.pointee.configure(force: true)
    return memory
}

@_noLocks
@c(inzone_dsp_connect)
private func connect(_ handle: LADSPA_Handle?, _ port: CUnsignedLong,
                     _ data: UnsafeMutablePointer<LADSPA_Data>?) {
    guard port < 11, let handle else { return }
    handle.assumingMemoryBound(to: PluginState.self).pointee.ports[Int(port)] = data
}

@_noLocks
@c(inzone_dsp_activate)
private func activate(_ handle: LADSPA_Handle?) {
    guard let handle else { return }
    handle.assumingMemoryBound(to: PluginState.self).pointee.configure(force: true)
}

@_noLocks
@c(inzone_dsp_run)
private func run(_ handle: LADSPA_Handle?, _ frames: CUnsignedLong) {
    guard let handle, frames <= CUnsignedLong(Int.max) else { return }
    let state = handle.assumingMemoryBound(to: PluginState.self)
    state.pointee.configure(force: false)
    if state.pointee.kind.firBank != nil {
        if let latency = state.pointee.ports[10] { latency.pointee = 0 }
        guard frames > 0, let outputLeft = state.pointee.ports[8],
              let outputRight = state.pointee.ports[9] else { return }
        for frame in 0..<Int(frames) {
            // Every input is captured before either output is written for aliased hosts.
            var inputs: InlineArray<8, Float> = .init(repeating: 0)
            for channel in 0..<8 { inputs[channel] = state.pointee.ports[channel]?[frame] ?? 0 }
            let output = state.pointee.fir.process(inputs: inputs)
            outputLeft[frame] = output.left
            outputRight[frame] = output.right
        }
        return
    }
    if state.pointee.kind == .spatial, let latency = state.pointee.ports[5] {
        latency.pointee = 32
    }
    let mono = state.pointee.kind == .microphone || state.pointee.kind == .biquad
        || state.pointee.kind == .equalizerBiquad
    guard frames > 0, let inputLeft = state.pointee.ports[0],
          let outputLeft = state.pointee.ports[mono ? 1 : 2] else { return }
    let inputRight = state.pointee.ports[1]
    let outputRight = state.pointee.ports[3]
    if !mono && (inputRight == nil || outputRight == nil) { return }

    for frame in 0..<Int(frames) {
        // Both channels are read before either output is written for in-place hosts.
        var left = inputLeft[frame]
        var right: Float = mono ? 0 : inputRight![frame]
        if !left.isFinite { left = 0 }
        if !right.isFinite { right = 0 }
        switch state.pointee.kind {
        case .firStandard, .firPersonal, .firDownmix:
            break
        case .spatial:
            state.pointee.processSpatial(left: &left, right: &right)
        case .biquad, .equalizerBiquad:
            left = state.pointee.processBiquad(left)
        case .automaticLevel:
            state.pointee.automaticLevel.process(left: &left, right: &right)
        case .dynamicRange, .microphone:
            state.pointee.dynamicRange.process(left: &left, right: &right)
        }
        outputLeft[frame] = left
        if !mono { outputRight![frame] = right }
    }
}

@c(inzone_dsp_cleanup)
private func cleanup(_ handle: LADSPA_Handle?) {
    guard let handle else { return }
    let state = handle.assumingMemoryBound(to: PluginState.self)
    state.pointee.fir.release()
    state.deinitialize(count: 1)
    free(handle)
}

private struct DescriptorStorage: @unchecked Sendable {
    let descriptors: UnsafeMutablePointer<LADSPA_Descriptor>
    let ports: UnsafeMutablePointer<LADSPA_PortDescriptor>
    let names: UnsafeMutablePointer<UnsafePointer<CChar>?>
    let hints: UnsafeMutablePointer<LADSPA_PortRangeHint>

    init() {
        descriptors = .allocate(capacity: 9)
        ports = .allocate(capacity: 99)
        names = .allocate(capacity: 99)
        hints = .allocate(capacity: 99)
        descriptors.initialize(repeating: LADSPA_Descriptor(), count: 9)
        ports.initialize(repeating: 0, count: 99)
        names.initialize(repeating: nil, count: 99)
        hints.initialize(repeating: LADSPA_PortRangeHint(), count: 99)
    }

    func release() {
        descriptors.deinitialize(count: 9)
        ports.deinitialize(count: 99)
        names.deinitialize(count: 99)
        hints.deinitialize(count: 99)
        descriptors.deallocate()
        ports.deallocate()
        names.deallocate()
        hints.deallocate()
    }

    func define(_ kind: PluginKind, label: StaticString, title: StaticString,
                portDescriptors: [LADSPA_PortDescriptor], portNames: [StaticString],
                portHints: [LADSPA_PortRangeHint]) {
        let index = kind.rawValue
        let offset = index * 11
        for port in portDescriptors.indices {
            ports[offset + port] = portDescriptors[port]
            names[offset + port] = staticCString(portNames[port])
            hints[offset + port] = portHints[port]
        }
        var descriptor = LADSPA_Descriptor()
        descriptor.UniqueID = CUnsignedLong(59_870 + index)
        descriptor.Label = staticCString(label)
        descriptor.Properties = LADSPA_PROPERTY_HARD_RT_CAPABLE
        descriptor.Name = staticCString(title)
        descriptor.Maker = staticCString("inzone-linux")
        descriptor.Copyright = staticCString("Local interoperability implementation")
        descriptor.PortCount = CUnsignedLong(portDescriptors.count)
        descriptor.PortDescriptors = UnsafePointer(ports + offset)
        descriptor.PortNames = UnsafePointer(names + offset)
        descriptor.PortRangeHints = UnsafePointer(hints + offset)
        descriptor.ImplementationData = UnsafeMutableRawPointer(bitPattern: index)
        descriptor.instantiate = instantiate
        descriptor.connect_port = connect
        descriptor.activate = activate
        descriptor.run = run
        descriptor.cleanup = cleanup
        descriptors[index] = descriptor
    }
}

private func staticCString(_ string: StaticString) -> UnsafePointer<CChar> {
    UnsafeRawPointer(string.utf8Start).assumingMemoryBound(to: CChar.self)
}

private func hint(_ descriptor: LADSPA_PortRangeHintDescriptor = 0,
                  _ lower: Float = 0, _ upper: Float = 0) -> LADSPA_PortRangeHint {
    LADSPA_PortRangeHint(HintDescriptor: descriptor, LowerBound: lower, UpperBound: upper)
}

// This POD pointer record lets the ELF finalizer release metadata without initializing it.
nonisolated(unsafe) private var storageToRelease: DescriptorStorage?

private let descriptorStorage: DescriptorStorage = {
    let storage = DescriptorStorage()
    let audioInput = LADSPA_PORT_AUDIO | LADSPA_PORT_INPUT
    let audioOutput = LADSPA_PORT_AUDIO | LADSPA_PORT_OUTPUT
    let controlInput = LADSPA_PORT_CONTROL | LADSPA_PORT_INPUT
    let controlOutput = LADSPA_PORT_CONTROL | LADSPA_PORT_OUTPUT
    let bounded = LADSPA_HINT_BOUNDED_BELOW | LADSPA_HINT_BOUNDED_ABOVE
    let defaultZero = LADSPA_HINT_DEFAULT_0
    let defaultOne = LADSPA_HINT_DEFAULT_1
    let integer = LADSPA_HINT_INTEGER
    let stereoPorts = [audioInput, audioInput, audioOutput, audioOutput]
    let firPorts = Array(repeating: audioInput, count: 8) + [audioOutput, audioOutput, controlOutput]
    let firNames: [StaticString] = [
        "Input FL", "Input FR", "Input FC", "Input LFE", "Input RL", "Input RR", "Input SL", "Input SR",
        "Output L", "Output R", "latency",
    ]
    let firHints = Array(repeating: hint(), count: 10) + [hint(bounded, 0, 0)]

    storage.define(.spatial, label: "inzone_spatial_alc",
                   title: "INZONE spatial automatic level control",
                   portDescriptors: stereoPorts + [controlInput, controlOutput],
                   portNames: ["Input L", "Input R", "Output L", "Output R", "Boost", "latency"],
                   portHints: [hint(), hint(), hint(), hint(),
                               hint(bounded | integer | defaultOne, 0, 1), hint(bounded, 32, 32)])
    storage.define(.dynamicRange, label: "inzone_drc",
                   title: "INZONE game dynamic range control",
                   portDescriptors: stereoPorts + [controlInput],
                   portNames: ["Input L", "Input R", "Output L", "Output R", "Mode"],
                   portHints: [hint(), hint(), hint(), hint(), hint(bounded | integer | defaultZero, 0, 2)])
    storage.define(.automaticLevel, label: "inzone_alc", title: "INZONE automatic level control",
                   portDescriptors: stereoPorts + [controlInput, controlInput, controlInput, controlInput, controlInput],
                   portNames: ["Input L", "Input R", "Output L", "Output R", "Enable", "Threshold", "Ratio", "Attack", "Release"],
                   portHints: [hint(), hint(), hint(), hint(),
                               hint(bounded | integer | defaultOne, 0, 1),
                               hint(bounded | LADSPA_HINT_DEFAULT_HIGH, -60, 0),
                               hint(bounded | LADSPA_HINT_DEFAULT_MAXIMUM, 1, 1_000),
                               hint(bounded | LADSPA_HINT_LOGARITHMIC | LADSPA_HINT_DEFAULT_LOW, 0.0001, 2),
                               hint(bounded | defaultOne, 0.0001, 10)])
    storage.define(.microphone, label: "inzone_mic_agc", title: "INZONE microphone automatic gain",
                   portDescriptors: [audioInput, audioOutput, controlInput],
                   portNames: ["Input", "Output", "Enable"],
                   portHints: [hint(), hint(), hint(bounded | integer | defaultOne, 0, 1)])

    let biquadPorts = [audioInput, audioOutput, controlInput, controlInput, controlInput, controlInput, controlInput]
    let biquadNames: [StaticString] = ["Input", "Output", "b0", "b1", "b2", "a1", "a2"]
    let biquadHints = [hint(), hint(), hint(bounded | defaultOne, -64, 64),
                       hint(bounded | defaultZero, -64, 64), hint(bounded | defaultZero, -64, 64),
                       hint(bounded | defaultZero, -64, 64), hint(bounded | defaultZero, -64, 64)]
    storage.define(.biquad, label: "inzone_biquad", title: "INZONE model biquad (double state)",
                   portDescriptors: biquadPorts, portNames: biquadNames, portHints: biquadHints)
    storage.define(.equalizerBiquad, label: "inzone_eq_biquad", title: "INZONE user EQ biquad (float state)",
                   portDescriptors: biquadPorts, portNames: biquadNames, portHints: biquadHints)
    storage.define(.firStandard, label: "inzone_fir_standard", title: "INZONE standard 7.1 FIR",
                   portDescriptors: firPorts, portNames: firNames, portHints: firHints)
    storage.define(.firPersonal, label: "inzone_fir_personal", title: "INZONE personalized 7.1 FIR",
                   portDescriptors: firPorts, portNames: firNames, portHints: firHints)
    storage.define(.firDownmix, label: "inzone_fir_downmix", title: "INZONE disabled-surround downmix FIR",
                   portDescriptors: firPorts, portNames: firNames, portHints: firHints)
    storageToRelease = storage
    return storage
}()

@c(ladspa_descriptor)
public func descriptorAt(_ index: CUnsignedLong) -> UnsafePointer<LADSPA_Descriptor>? {
    guard index < 9 else { return nil }
    return UnsafePointer(descriptorStorage.descriptors + Int(index))
}

// The linker registers this function as DT_FINI so dlclose releases all metadata storage.
@c(inzone_dsp_finalize)
public func finalizeDescriptors() {
    storageToRelease?.release()
    storageToRelease = nil
}
