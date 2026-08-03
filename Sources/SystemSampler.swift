import Darwin
import Foundation

/// RAM usage / memory pressure (public APIs) and network throughput
/// (interface byte-counter deltas, rolling baseline like IOReportSampler).
final class SystemSampler {

    struct Memory {
        var usedBytes: UInt64
        var totalBytes: UInt64
        var pressure: String   // "ok" / "warning" / "critical"
    }

    struct Network {
        var downBps: Double
        var upBps: Double
    }

    struct Storage {
        var swapUsedBytes: UInt64
        var swapTotalBytes: UInt64
        var diskUsedBytes: UInt64
        var diskTotalBytes: UInt64
    }

    // Per-interface 32-bit counters: if_data byte counts wrap at 4 GiB, so
    // deltas are computed per interface with modular arithmetic, then summed.
    private var lastCounters: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var lastTime = DispatchTime.now()
    private var primed = false

    // MARK: RAM

    func memory() -> Memory? {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0, total > 0
        else { return nil }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        // Same accounting Activity Monitor uses for "memory used":
        // app (active + speculative − purgeable) is close enough at a glance —
        // we keep it simple: active + wired + compressed.
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * pageSize

        var level: Int32 = 1
        var lsize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lsize, nil, 0)
        let pressure = level >= 4 ? "critical" : (level >= 2 ? "warning" : "ok")

        return Memory(usedBytes: used, totalBytes: total, pressure: pressure)
    }

    // MARK: Storage (swap + SSD fill level)

    /// Swap lives on the SSD, so both belong together: how much swap macOS has
    /// written out, and how full the whole disk is. Disk numbers use the same
    /// "important usage" capacity Finder reports (purgeable space counts as free).
    func storage() -> Storage? {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return nil }

        let url = URL(fileURLWithPath: "/")
        guard let vals = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]), let total = vals.volumeTotalCapacity,
           let avail = vals.volumeAvailableCapacityForImportantUsage, total > 0
        else { return nil }

        return Storage(swapUsedBytes: swap.xsu_used,
                       swapTotalBytes: swap.xsu_total,
                       diskUsedBytes: UInt64(max(Int64(total) - avail, 0)),
                       diskTotalBytes: UInt64(total))
    }

    // MARK: Network

    /// Byte-rate since the previous call; nil on the priming call.
    /// Counts physical `en*` interfaces only — VPN traffic would otherwise be
    /// counted twice (clear on utun*, encrypted again on en0), and awdl/bridge
    /// chatter would inflate idle numbers.
    func network() -> Network? {
        var counters: [String: (rx: UInt32, tx: UInt32)] = [:]
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else { return nil }
        defer { freeifaddrs(ifaddrsPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let dataRaw = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let data = dataRaw.assumingMemoryBound(to: if_data.self).pointee
            counters[name] = (data.ifi_ibytes, data.ifi_obytes)
        }

        let now = DispatchTime.now()
        let dt = Double(now.uptimeNanoseconds - lastTime.uptimeNanoseconds) / 1e9
        defer { lastCounters = counters; lastTime = now; primed = true }
        guard primed, dt > 0.5 else { return nil }

        var down: UInt64 = 0, up: UInt64 = 0
        for (name, c) in counters {
            guard let prev = lastCounters[name] else { continue }
            down &+= UInt64(c.rx &- prev.rx)   // modular: correct across wrap
            up &+= UInt64(c.tx &- prev.tx)
        }
        return Network(downBps: Double(down) / dt, upBps: Double(up) / dt)
    }

    /// "2.1 MB/s", "340 kB/s", "12 B/s"
    static func rate(_ bps: Double) -> String {
        switch bps {
        case ..<1_000: return String(format: "%.0f B/s", bps)
        case ..<1_000_000: return String(format: "%.0f kB/s", bps / 1_000)
        default: return String(format: "%.1f MB/s", bps / 1_000_000)
        }
    }
}
