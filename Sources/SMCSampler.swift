import Foundation
import IOKit

/// Fan telemetry via the SMC (AppleSMCKeysEndpoint, no root).
/// Struct layout ported from exelban/stats; tested standalone on this
/// machine (M1 Pro, macOS 26.5) before integration.
final class SMCSampler {

    struct Fan {
        var rpm: Double
        var min: Double
        var max: Double
        var isRunning: Bool { rpm >= 100 }
    }

    // MARK: SMC structs (field order is ABI — do not reorder)

    private struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0,
                              reserved: UInt8 = 0, release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0,
                                cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }
    private typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    private struct KeyData {
        var key: UInt32 = 0
        var vers = Vers()
        var pLimitData = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                              0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let kernelIndex: UInt32 = 2

    private var connection: io_connect_t = 0
    private let fanCount: Int
    private let minMax: [(Double, Double)]   // cached — hardware constants

    init?() {
        var conn: io_connect_t = 0
        var opened = false
        for name in ["AppleSMCKeysEndpoint", "AppleSMC"] {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
            guard service != 0 else { continue }
            let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
            IOObjectRelease(service)
            if kr == KERN_SUCCESS { opened = true; break }
        }
        guard opened else { return nil }
        connection = conn

        guard let n = Self.value(conn, "FNum"), n > 0, n <= 8 else {
            IOServiceClose(conn)
            return nil
        }
        fanCount = Int(n)
        minMax = (0..<fanCount).map {
            (Self.value(conn, "F\($0)Mn") ?? 0, Self.value(conn, "F\($0)Mx") ?? 0)
        }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func fans() -> [Fan] {
        (0..<fanCount).map { i in
            Fan(rpm: Self.value(connection, "F\(i)Ac") ?? 0,
                min: minMax[i].0, max: minMax[i].1)
        }
    }

    // MARK: key reading

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func call(_ conn: io_connect_t, _ input: inout KeyData, _ output: inout KeyData) -> kern_return_t {
        var outSize = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(conn, kernelIndex, &input,
                                         MemoryLayout<KeyData>.stride, &output, &outSize)
    }

    private static func value(_ conn: io_connect_t, _ key: String) -> Double? {
        var input = KeyData()
        var output = KeyData()
        input.key = fourCC(key)
        input.data8 = cmdReadKeyInfo
        guard call(conn, &input, &output) == KERN_SUCCESS, output.keyInfo.dataSize > 0
        else { return nil }

        let size = output.keyInfo.dataSize
        let type = output.keyInfo.dataType
        input = KeyData()
        input.key = fourCC(key)
        input.keyInfo.dataSize = size
        input.data8 = cmdReadBytes
        output = KeyData()
        guard call(conn, &input, &output) == KERN_SUCCESS else { return nil }

        let b = output.bytes
        switch type {
        case fourCC("ui8 "): return Double(b.0)
        case fourCC("ui16"): return Double((UInt16(b.0) << 8) | UInt16(b.1))
        case fourCC("ui32"):
            return Double((UInt32(b.0) << 24) | (UInt32(b.1) << 16) | (UInt32(b.2) << 8) | UInt32(b.3))
        case fourCC("flt "):
            var f: Float = 0
            withUnsafeMutableBytes(of: &f) { $0.copyBytes(from: [b.0, b.1, b.2, b.3]) }
            return Double(f)
        case fourCC("fpe2"): return Double((Int(b.0) << 6) + (Int(b.1) >> 2))
        default: return nil
        }
    }
}
