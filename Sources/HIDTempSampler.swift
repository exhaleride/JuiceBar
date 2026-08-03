import CoreFoundation
import Darwin
import Foundation

/// Temperature sensors via IOHIDEventSystemClient (private SPI, no root) —
/// the macmon/Stats pattern, tested standalone on this machine.
/// M1-family names: "PMU tdie*" (SoC dies), "PMU tdev*" (board), "NAND CH0
/// temp" (SSD), "gas gauge battery". Duplicate names come from multiple HID
/// services — deduped here keeping the hottest reading.
final class HIDTempSampler {

    struct Curated {
        var cpu: Double?     // hottest SoC die
        var gpu: Double?     // only when a GPU-named sensor exists
        var ssd: Double?
        var battery: Double?
    }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef?, CFDictionary?) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef?) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef?, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef?, Int64) -> Double

    private let fCopyProperty: CopyPropertyFn
    private let fCopyEvent: CopyEventFn
    private let fGetFloat: GetFloatFn
    private let client: CFTypeRef
    private let services: CFArray

    private static let eventTypeTemperature: Int64 = 15

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        else { return nil }
        func bind<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let create = bind("IOHIDEventSystemClientCreate", CreateFn.self),
            let setMatching = bind("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
            let copyServices = bind("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
            let copyProperty = bind("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
            let copyEvent = bind("IOHIDServiceClientCopyEvent", CopyEventFn.self),
            let getFloat = bind("IOHIDEventGetFloatValue", GetFloatFn.self)
        else { return nil }
        fCopyProperty = copyProperty
        fCopyEvent = copyEvent
        fGetFloat = getFloat

        guard let clientU = create(nil) else { return nil }
        let c = clientU.takeRetainedValue()
        setMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x0005] as CFDictionary)
        guard let servicesU = copyServices(c) else { return nil }
        let s = servicesU.takeRetainedValue()
        guard CFArrayGetCount(s) > 0 else { return nil }
        client = c
        services = s
    }

    /// All sensors, deduped by name (hottest wins), sorted, 0…130 °C filtered.
    func all() -> [(name: String, celsius: Double)] {
        var byName: [String: Double] = [:]
        for i in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()

            var name = "?"
            if let nameU = fCopyProperty(service, "Product" as CFString) {
                let ref = nameU.takeRetainedValue()
                if CFGetTypeID(ref) == CFStringGetTypeID() {
                    name = (ref as! CFString) as String
                }
            }
            guard let eventU = fCopyEvent(service, Self.eventTypeTemperature, 0, 0) else { continue }
            let event = eventU.takeRetainedValue()
            let t = fGetFloat(event, Self.eventTypeTemperature << 16)
            guard t > 0, t < 130 else { continue }
            byName[name] = Swift.max(byName[name] ?? -.infinity, t)
        }
        return byName.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    func curated() -> Curated {
        var c = Curated()
        for (name, t) in all() {
            let lower = name.lowercased()
            func bump(_ v: inout Double?) { v = Swift.max(v ?? -.infinity, t) }
            if lower.contains("tdie") || lower.contains("soc mtr")
                || lower.contains("pacc") || lower.contains("eacc") {
                bump(&c.cpu)
            } else if lower.contains("gpu") {
                bump(&c.gpu)
            } else if lower.contains("nand") {
                bump(&c.ssd)
            } else if lower.contains("gas gauge") {
                bump(&c.battery)
            }
        }
        return c
    }
}
