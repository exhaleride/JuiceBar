import CoreFoundation
import Darwin
import Foundation
import IOKit

/// SoC-level readings from the private IOReport API.
/// All optional — rows are hidden in the UI when a source is unavailable.
struct SocSample {
    var cpuW: Double?
    var gpuW: Double?
    var aneW: Double?

    /// Other measured on-chip consumers (memory, media engine, camera ISP,
    /// PCIe) — everything here is part of "Rest" in the UI's power breakdown.
    var otherW: [(name: String, watts: Double)] = []

    var eFreqMHz: Double?
    var eMaxMHz: Double?
    var pFreqMHz: Double?
    var pMaxMHz: Double?
    var gpuFreqMHz: Double?
    var gpuMaxMHz: Double?

    /// Busy share per cluster (active residency), 0…1.
    var eActive: Double?
    var pActive: Double?
    var gpuActive: Double?

    /// Worst frequency ratio among BUSY clusters (throttle proxy), 0…1.
    /// A lightly-loaded cluster legitimately clocks down (DVFS) — low frequency
    /// only signals throttling when the cluster is actually working hard.
    var worstFreqRatio: Double? {
        let ratios = [(pFreqMHz, pMaxMHz, pActive), (gpuFreqMHz, gpuMaxMHz, gpuActive)]
            .compactMap { f, m, a -> Double? in
                guard let f, let m, let a, m > 0, a > 0.85 else { return nil }
                return f / m
            }
        return ratios.min()
    }
}

/// Reads Apple's private IOReport API (no sudo) for SoC power and per-cluster
/// frequency-state residency. libIOReport.dylib lives only in the dyld shared
/// cache, so it's bound at runtime via dlopen/dlsym. Channel names, the
/// residency→frequency math, and unit handling mirror macmon
/// (github.com/vladkens/macmon); tested standalone on this machine
/// (M1 Pro, macOS 26.5) before integration.
final class IOReportSampler {

    // MARK: bound C functions

    private typealias CopyAllChannelsT = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscriptionT = @convention(c) (
        UnsafeMutableRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?
    ) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesT =
        @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDeltaT =
        @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetStringT = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateGetCountT = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetNameT = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateGetResidencyT = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias SimpleGetIntegerT = @convention(c) (CFDictionary, Int32) -> Int64

    private let fCopyAllChannels: CopyAllChannelsT
    private let fCreateSamples: CreateSamplesT
    private let fCreateSamplesDelta: CreateSamplesDeltaT
    private let fGetGroup: GetStringT
    private let fGetSubGroup: GetStringT
    private let fGetChannelName: GetStringT
    private let fGetUnitLabel: GetStringT
    private let fStateGetCount: StateGetCountT
    private let fStateGetName: StateGetNameT
    private let fStateGetResidency: StateGetResidencyT
    private let fSimpleGetInteger: SimpleGetIntegerT

    // MARK: state

    private let subscription: UnsafeMutableRawPointer
    private let subbedChannels: CFMutableDictionary
    private var baseline: CFDictionary
    private var baselineTime: DispatchTime
    private var cached = SocSample()

    private let eFreqs: [UInt32]
    private let pFreqs: [UInt32]
    private let gFreqs: [UInt32]
    private let eMax: Double
    private let pMax: Double
    private let gMax: Double

    // MARK: init (returns nil on any failure → app degrades gracefully)

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func bind<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let copyAll = bind("IOReportCopyAllChannels", CopyAllChannelsT.self),
            let createSub = bind("IOReportCreateSubscription", CreateSubscriptionT.self),
            let createSamples = bind("IOReportCreateSamples", CreateSamplesT.self),
            let createDelta = bind("IOReportCreateSamplesDelta", CreateSamplesDeltaT.self),
            let getGroup = bind("IOReportChannelGetGroup", GetStringT.self),
            let getSubGroup = bind("IOReportChannelGetSubGroup", GetStringT.self),
            let getChannelName = bind("IOReportChannelGetChannelName", GetStringT.self),
            let getUnitLabel = bind("IOReportChannelGetUnitLabel", GetStringT.self),
            let stateCount = bind("IOReportStateGetCount", StateGetCountT.self),
            let stateName = bind("IOReportStateGetNameForIndex", StateGetNameT.self),
            let stateResidency = bind("IOReportStateGetResidency", StateGetResidencyT.self),
            let simpleGet = bind("IOReportSimpleGetIntegerValue", SimpleGetIntegerT.self)
        else { return nil }

        fCopyAllChannels = copyAll
        fCreateSamples = createSamples
        fCreateSamplesDelta = createDelta
        fGetGroup = getGroup
        fGetSubGroup = getSubGroup
        fGetChannelName = getChannelName
        fGetUnitLabel = getUnitLabel
        fStateGetCount = stateCount
        fStateGetName = stateName
        fStateGetResidency = stateResidency
        fSimpleGetInteger = simpleGet

        // DVFS frequency tables from the pmgr IORegistry node.
        // Missing tables zero out the freq rows but leave energy working.
        let pmgr = Self.findPmgrProperties()
        eFreqs = pmgr.flatMap { Self.loadFreqTableMHz($0, key: "voltage-states1-sram") } ?? []
        pFreqs = pmgr.flatMap { Self.loadFreqTableMHz($0, key: "voltage-states5-sram") } ?? []
        // GPU residency states are [OFF, s1..sN]; raw table has one extra
        // leading entry (0) — drop it to align (macmon: gpu_freqs[1..]).
        let gRaw = pmgr.flatMap { Self.loadFreqTableMHz($0, key: "voltage-states9") } ?? []
        gFreqs = gRaw.count > 1 ? Array(gRaw.dropFirst()) : gRaw
        eMax = Double(eFreqs.last ?? 0)
        pMax = Double(pFreqs.last ?? 0)
        gMax = Double(gFreqs.last ?? 0)

        // Filter channels to the three groups we read, then subscribe.
        guard let allUnmanaged = fCopyAllChannels(0, 0) else { return nil }
        let all = allUnmanaged.takeRetainedValue()
        guard let arr = Self.channelsArray(all) else { return nil }
        let count = CFArrayGetCount(arr)
        var cb = kCFTypeArrayCallBacks
        guard let filtered = CFArrayCreateMutable(kCFAllocatorDefault, count, &cb) else { return nil }
        var matched = 0
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
            let item = Unmanaged<CFDictionary>.fromOpaque(raw).takeUnretainedValue()
            if wantsChannel(group: cfstr(fGetGroup(item)),
                            subgroup: cfstr(fGetSubGroup(item)),
                            channel: cfstr(fGetChannelName(item))) {
                CFArrayAppendValue(filtered, raw)
                matched += 1
            }
        }
        guard matched > 0,
              let chanDict = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, all)
        else { return nil }
        let key = "IOReportChannels" as CFString
        CFDictionarySetValue(chanDict, Unmanaged.passUnretained(key).toOpaque(),
                             Unmanaged.passUnretained(filtered).toOpaque())

        var subbedUnmanaged: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, chanDict, &subbedUnmanaged, 0, nil),
              let subbed = subbedUnmanaged?.takeRetainedValue()
        else { return nil }
        subscription = sub
        subbedChannels = subbed

        guard let first = createSamples(sub, subbed, nil) else { return nil }
        baseline = first.takeRetainedValue()
        baselineTime = DispatchTime.now()
    }

    // MARK: sampling

    func sample(intervalSeconds: Double) -> SocSample {
        let now = DispatchTime.now()
        let dt = Double(now.uptimeNanoseconds - baselineTime.uptimeNanoseconds) / 1e9
        // Deltas over sub-second windows are noise (e.g. menu opened right
        // after a timer tick) — serve the last result instead.
        guard dt >= 0.5 else { return cached }

        guard let newUnmanaged = fCreateSamples(subscription, subbedChannels, nil) else { return cached }
        let newSample = newUnmanaged.takeRetainedValue()
        guard let deltaUnmanaged = fCreateSamplesDelta(baseline, newSample, nil) else { return cached }
        let delta = deltaUnmanaged.takeRetainedValue()
        baseline = newSample
        baselineTime = now

        cached = process(delta, dtSeconds: dt)
        return cached
    }

    private func process(_ delta: CFDictionary, dtSeconds: Double) -> SocSample {
        var out = SocSample()
        guard let arr = Self.channelsArray(delta) else { return out }

        var cpuJ = 0.0, gpuJ = 0.0, aneJ = 0.0
        var otherJ: [String: Double] = [:]
        var eCores: [(freq: Double, active: Double)] = []
        var pCores: [(freq: Double, active: Double)] = []
        var gpuMhz = 0.0, gpuAct = 0.0

        for i in 0..<CFArrayGetCount(arr) {
            guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
            let item = Unmanaged<CFDictionary>.fromOpaque(raw).takeUnretainedValue()
            let group = cfstr(fGetGroup(item))

            if group == "Energy Model" {
                let channel = cfstr(fGetChannelName(item))
                let unit = cfstr(fGetUnitLabel(item)).trimmingCharacters(in: .whitespaces)
                let j = joules(fSimpleGetInteger(item, 0), unit: unit)
                if channel == "GPU Energy" { gpuJ += j }
                else if channel.hasSuffix("CPU Energy") { cpuJ += j }
                else if channel.hasPrefix("ANE") { aneJ += j }
                else if let bucket = otherEnergyBucket(channel) { otherJ[bucket, default: 0] += j }
                continue
            }

            let subgroup = cfstr(fGetSubGroup(item))
            if group == "CPU Stats" && subgroup == "CPU Core Performance States" {
                if let kind = coreKind(cfstr(fGetChannelName(item))) {
                    switch kind {
                    case .p: pCores.append(freqFromResidencies(item, pFreqs))
                    case .e: eCores.append(freqFromResidencies(item, eFreqs))
                    }
                }
            } else if group == "GPU Stats" && subgroup == "GPU Performance States" {
                if cfstr(fGetChannelName(item)).hasPrefix("GPUPH") {
                    let r = freqFromResidencies(item, gFreqs)
                    gpuMhz = r.freq
                    gpuAct = r.active
                }
            }
        }

        out.cpuW = cpuJ / dtSeconds
        out.gpuW = gpuJ / dtSeconds
        out.aneW = aneJ / dtSeconds
        out.otherW = otherJ.map { (name: $0.key, watts: $0.value / dtSeconds) }
            .sorted { $0.watts > $1.watts }
        func meanActive(_ cores: [(freq: Double, active: Double)]) -> Double {
            cores.isEmpty ? 0 : cores.reduce(0.0) { $0 + $1.active } / Double(cores.count)
        }
        if eMax > 0 { out.eMaxMHz = eMax; out.eFreqMHz = aggregate(eCores); out.eActive = meanActive(eCores) }
        if pMax > 0 { out.pMaxMHz = pMax; out.pFreqMHz = aggregate(pCores); out.pActive = meanActive(pCores) }
        if gMax > 0 { out.gpuMaxMHz = gMax; out.gpuFreqMHz = gpuMhz; out.gpuActive = gpuAct }
        return out
    }

    // MARK: residency → frequency (mirrors macmon)

    /// Average active frequency (MHz) + active ratio, skipping leading
    /// IDLE/DOWN/OFF states.
    private func freqFromResidencies(_ item: CFDictionary, _ freqs: [UInt32]) -> (freq: Double, active: Double) {
        guard !freqs.isEmpty else { return (0, 0) }
        let count = Int(fStateGetCount(item))
        var states: [(String, Int64)] = []
        states.reserveCapacity(count)
        for i in 0..<count {
            states.append((cfstr(fStateGetName(item, Int32(i))), fStateGetResidency(item, Int32(i))))
        }
        guard states.count > freqs.count,
              let offset = states.firstIndex(where: { !["IDLE", "DOWN", "OFF"].contains($0.0) }),
              offset + freqs.count <= states.count
        else { return (0, 0) }

        let usage = (0..<freqs.count).reduce(0.0) { $0 + Double(states[$1 + offset].1) }
        let total = states.reduce(0.0) { $0 + Double($1.1) }
        guard usage > 0 else { return (0, 0) }
        var avg = 0.0
        for i in 0..<freqs.count {
            avg += (Double(states[i + offset].1) / usage) * Double(freqs[i])
        }
        return (avg, total > 0 ? usage / total : 0)
    }

    /// Cluster average weighted by each core's active residency
    /// (macmon's aggregate_active_frequency).
    private func aggregate(_ cores: [(freq: Double, active: Double)]) -> Double {
        let activeSum = cores.reduce(0.0) { $0 + $1.active }
        guard activeSum > 0 else { return 0 }
        return cores.reduce(0.0) { $0 + $1.freq * $1.active } / activeSum
    }

    private enum CoreKind { case e, p }

    /// "ECPUn" / "PCPUn" / "MCPUn" (M5+), tolerating "DIE_n_" prefixes on Ultra.
    private func coreKind(_ channel: String) -> CoreKind? {
        if channel.contains("PCPU") { return .p }
        if channel.contains("ECPU") || channel.contains("MCPU") { return .e }
        return nil
    }

    private func joules(_ raw: Int64, unit: String) -> Double {
        switch unit {
        case "mJ": return Double(raw) / 1e3
        case "uJ", "µJ": return Double(raw) / 1e6
        default: return Double(raw) / 1e9   // nJ — the observed unit on Apple Silicon
        }
    }

    // MARK: CF/IORegistry helpers

    private static func channelsArray(_ dict: CFDictionary) -> CFArray? {
        let key = "IOReportChannels" as CFString
        guard let raw = CFDictionaryGetValue(dict, Unmanaged.passUnretained(key).toOpaque())
        else { return nil }
        return Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func findPmgrProperties() -> CFDictionary? {
        guard let matching = IOServiceMatching("AppleARMIODevice") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var nameBuf = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetName(entry, &nameBuf) == KERN_SUCCESS,
               String(cString: nameBuf) == "pmgr" {
                var props: Unmanaged<CFMutableDictionary>?
                let ok = IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
                IOObjectRelease(entry)
                return ok == KERN_SUCCESS ? props?.takeRetainedValue() : nil
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return nil
    }

    /// Parse a pmgr "voltage-statesN[-sram]" blob: (uint32 freq_le, uint32 volt_le)
    /// pairs. Raw unit varies by chip (Hz on M1–M3, kHz on M4+) — auto-scale so
    /// the table max lands in a plausible 300–6000 MHz window.
    private static func loadFreqTableMHz(_ dict: CFDictionary, key: String) -> [UInt32]? {
        let cfKey = key as CFString
        guard let raw = CFDictionaryGetValue(dict, Unmanaged.passUnretained(cfKey).toOpaque())
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        let length = CFDataGetLength(data)
        guard length > 0, length % 8 == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        CFDataGetBytes(data, CFRange(location: 0, length: length), &buffer)

        var freqs: [UInt32] = []
        var i = 0
        while i + 8 <= length {
            freqs.append(UInt32(buffer[i]) | (UInt32(buffer[i+1]) << 8)
                       | (UInt32(buffer[i+2]) << 16) | (UInt32(buffer[i+3]) << 24))
            i += 8
        }
        guard let maxRaw = freqs.max(), maxRaw > 0 else { return nil }
        for scale in [1_000_000.0, 1_000.0, 1.0] {
            if (300...6000).contains(Double(maxRaw) / scale) {
                return freqs.map { UInt32((Double($0) / scale).rounded()) }
            }
        }
        return freqs.map { UInt32((Double($0) / 1_000_000.0).rounded()) }
    }
}

private func cfstr(_ u: Unmanaged<CFString>?) -> String {
    guard let u else { return "" }
    return u.takeUnretainedValue() as String
}

/// Groups the remaining Energy Model channels into user-facing buckets.
/// Per-core/per-cluster CPU duplicates (EACC_*, PACC*, *CPUDTL*) fall through
/// to nil so the "CPU Energy" total isn't double-counted.
private func otherEnergyBucket(_ channel: String) -> String? {
    if channel.hasPrefix("DRAM") || channel.hasPrefix("DCS") || channel.hasPrefix("AMCC") {
        return "Memory"
    }
    if channel.hasPrefix("AVE") || channel.hasPrefix("MSR") { return "Media engine" }
    if channel.hasPrefix("ISP") { return "Camera ISP" }
    if channel.hasPrefix("PCIe") || channel.hasPrefix("apciec") { return "PCIe (SSD/TB)" }
    return nil
}

private func wantsChannel(group: String, subgroup: String, channel: String) -> Bool {
    if group == "Energy Model" {
        return channel == "GPU Energy" || channel.hasSuffix("CPU Energy") || channel.hasPrefix("ANE")
            || otherEnergyBucket(channel) != nil
    }
    if group == "CPU Stats" { return subgroup == "CPU Core Performance States" }
    if group == "GPU Stats" { return subgroup == "GPU Performance States" }
    return false
}
