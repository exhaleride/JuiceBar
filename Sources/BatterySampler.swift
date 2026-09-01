import Foundation
import IOKit

/// One snapshot of the machine's power flow, read from the AppleSmartBattery
/// IORegistry node. All fields are optional — a missing key must never crash us.
struct PowerSnapshot {
    // IN
    var wallPowerW: Double?          // SystemPowerIn (mW→W); only valid on AC
    var adapterLossW: Double?        // AdapterEfficiencyLoss (mW→W)
    var adapterMaxW: Int?            // AdapterDetails.Watts — the NEGOTIATED
                                     // PD contract, not what's being drawn.
                                     // Multi-port chargers renegotiate lower
                                     // when a second device plugs in.
    var adapterVolts: Double?        // AdapterDetails.AdapterVoltage (mV→V)
    var adapterAmps: Double?         // AdapterDetails.Current (mA→A)
    var externalConnected: Bool = false

    // Raw battery electrics (for the measurement view)
    var batteryVolts: Double?
    var batteryAmps: Double?         // signed; + charging, − discharging

    // NET (battery). Positive = charging (into battery), negative = discharging.
    var batteryFlowW: Double?        // Voltage(mV) × InstantAmperage(mA) → W
    var isCharging: Bool = false
    var chargePercent: Int?          // CurrentCapacity (0–100 on Apple Silicon)
    var timeRemainingMin: Int?       // to full when charging, to empty when draining
    var batteryTempC: Double?        // Temperature / 100

    /// Charge cap in force (80…95), or nil when charging is unrestricted.
    /// Filled in by the delegate from ChargeLimit — not read from IOKit.
    var chargeLimit: Int?

    /// On the charger, sitting at the cap and deliberately not charging.
    /// Without this, a capped battery looks exactly like a stalled one: macOS
    /// reports IsCharging = false and the menu bar would go quiet. powerd lets
    /// the charge drift a few points below the cap before topping it up again,
    /// so the whole band counts as "held", not just the cap itself.
    var heldAtLimit: Bool {
        guard externalConnected, !isCharging,
              let cap = chargeLimit, let pct = chargePercent else { return false }
        return pct >= cap - 6
    }

    // OUT (derived): system draw = wall − loss − batteryFlow  (AC)
    //                             = −batteryFlow              (on battery)
    var systemPowerW: Double? {
        if externalConnected {
            guard let wall = wallPowerW else { return nil }
            let loss = adapterLossW ?? 0
            let batt = batteryFlowW ?? 0
            let sys = wall - loss - batt
            return sys > 0 ? sys : nil   // telemetry lags ~30 s around plug events
        } else {
            guard let batt = batteryFlowW else { return nil }
            return batt < 0 ? -batt : nil
        }
    }
}

enum BatterySampler {

    static func sample() -> PowerSnapshot {
        var snap = PowerSnapshot()

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return snap }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0)
                == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any]
        else { return snap }

        snap.externalConnected = (props["ExternalConnected"] as? Bool) ?? false
        snap.isCharging        = (props["IsCharging"] as? Bool) ?? false
        snap.chargePercent     = props["CurrentCapacity"] as? Int

        // Battery flow: mV × mA → µW → W. InstantAmperage is signed
        // (negative while discharging; CFNumber preserves the sign).
        if let mV = props["Voltage"] as? Int64,
           let mA = int64(props["InstantAmperage"]) {
            snap.batteryFlowW = Double(mV) * Double(mA) / 1_000_000.0
            snap.batteryVolts = Double(mV) / 1000.0
            snap.batteryAmps = Double(mA) / 1000.0
        }

        if let t = props["Temperature"] as? Int {
            snap.batteryTempC = Double(t) / 100.0
        }

        // 65535 = "calculating"/unknown
        if let mins = props["TimeRemaining"] as? Int, mins > 0, mins < 65535 {
            snap.timeRemainingMin = mins
        }

        if let adapter = props["AdapterDetails"] as? [String: Any] {
            snap.adapterMaxW = adapter["Watts"] as? Int
            if let mV = adapter["AdapterVoltage"] as? Int { snap.adapterVolts = Double(mV) / 1000 }
            if let mA = adapter["Current"] as? Int { snap.adapterAmps = Double(mA) / 1000 }
        }

        // Wall telemetry (updates ~every 30 s; only meaningful on AC)
        if snap.externalConnected,
           let tel = props["PowerTelemetryData"] as? [String: Any] {
            if let mW = int64(tel["SystemPowerIn"]), mW > 0 {
                snap.wallPowerW = Double(mW) / 1000.0
            }
            if let mW = int64(tel["AdapterEfficiencyLoss"]), mW >= 0 {
                snap.adapterLossW = Double(mW) / 1000.0
            }
        }

        return snap
    }

    /// Some battery values arrive as the unsigned bit pattern of a negative
    /// number (seen as 1.8e19 in ioreg). Reinterpret anything as signed Int64.
    private static func int64(_ any: Any?) -> Int64? {
        guard let n = any else { return nil }
        if let v = n as? Int64 { return v }
        if let v = n as? Int { return Int64(v) }
        if let v = n as? UInt64 { return Int64(bitPattern: v) }
        if let num = n as? NSNumber { return num.int64Value }
        return nil
    }
}
