import Foundation

// Charge limit — the same knob as System Settings › Battery › Charge Limit.
//
// macOS owns the limiter (PowerUIAgent + powerd); we just drive it through the
// private PowerUI framework, so there is no SMC write, no privileged helper and
// no admin password. The old third-party trick — writing SMC keys CH0B/CH0C/
// BCLM from a root helper — is dead on Apple silicon running macOS 26: those
// keys no longer exist in the SMC at all.
//
// Two things about this API were established by measurement, not documentation:
//
//   1. `setMCLLimit:error:` returns success and does nothing. The setter that
//      actually moves the limit is `temporarilyOverrideMCLTargetSoC:error:`.
//   2. That override lives only in PowerUIAgent's memory — nothing is written
//      to disk — so it is lost when the daemon restarts or the Mac reboots.
//      JuiceBar therefore remembers the chosen value itself and re-applies it
//      (see `reconcile` in main.swift). JuiceBar owns the setting; change it
//      from this menu rather than from System Settings.

/// Selectors on PowerUISmartChargeClient. Names are spelled out explicitly
/// because Swift would otherwise mangle a throwing method into
/// `…AndReturnError:`, which does not exist on the ObjC side.
@objc private protocol JBSmartChargeClient {
    @objc(initWithClientName:) init(clientName: String)
    @objc(isMCLSupported)                         func isMCLSupported() -> Bool
    @objc(getMCLLimitWithError:)                  func getMCLLimit(_ error: NSErrorPointer) -> UInt8
    @objc(isMCLCurrentlyEnabled:)                 func isMCLCurrentlyEnabled(_ error: NSErrorPointer) -> UInt
    @objc(isSmartChargingCurrentlyEnabled:)       func isOBCEnabled(_ error: NSErrorPointer) -> UInt
    @objc(availableChargeLimitsWithError:)        func availableChargeLimits() throws -> [NSNumber]
    @objc(temporarilyOverrideMCLTargetSoC:error:) func overrideTarget(_ limit: UInt8) throws
}

struct ChargeLimitState: Equatable {
    /// Target the limiter is holding, 80…100. 100 means "no limit".
    var limit: Int
    /// Whether the manual charge limit is engaged at all.
    var enabled: Bool
    /// Steps macOS offers on this Mac — normally 80, 85, 90, 95, 100.
    var available: [Int]
    /// Optimized Battery Charging (Apple's learning "wait until you need it" mode).
    var obcEnabled: Bool

    /// The cap actually in force, or nil when charging is unrestricted.
    var effectiveLimit: Int? { enabled && limit < 100 ? limit : nil }
}

final class ChargeLimit {

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"

    /// Full range if macOS ever hands us an empty list.
    private static let fallbackSteps = [80, 85, 90, 95, 100]

    private var client: JBSmartChargeClient?

    /// nil when this Mac has no manual charge limit (pre-26, Intel, or Apple
    /// moved the API) — the caller then hides the whole section.
    init?() {
        guard ProcessInfo.processInfo.environment["JUICEBAR_NO_CHARGELIMIT"] == nil,
              dlopen(Self.frameworkPath, RTLD_NOW) != nil,   // must precede NSClassFromString
              let c = Self.makeClient(),
              c.isMCLSupported()
        else { return nil }
        client = c
        // One real round-trip: the class can exist while the XPC service refuses us.
        guard state() != nil else { return nil }
    }

    private static func makeClient() -> JBSmartChargeClient? {
        guard let cls = NSClassFromString("PowerUISmartChargeClient") else { return nil }
        return unsafeBitCast(cls, to: JBSmartChargeClient.Type.self)
            .init(clientName: "JuiceBar")
    }

    /// Runs `body`, and on failure retries once against a fresh client — covers
    /// an XPC connection invalidated by a PowerUIAgent restart. A new client
    /// costs about a millisecond.
    private func withClient<T>(_ body: (JBSmartChargeClient) throws -> T) rethrows -> T? {
        if let c = client, let out = try? body(c) { return out }
        guard let fresh = Self.makeClient() else { return nil }
        client = fresh
        return try body(fresh)
    }

    func state() -> ChargeLimitState? {
        withClient { c -> ChargeLimitState? in
            var err: NSError?

            let limit = c.getMCLLimit(&err)
            guard err == nil else { return nil }

            let enabled = c.isMCLCurrentlyEnabled(&err)
            guard err == nil else { return nil }

            // Non-fatal: a missing OBC reading only costs us one status word.
            var obcErr: NSError?
            let obc = c.isOBCEnabled(&obcErr)

            let steps = (try? c.availableChargeLimits())?.map(\.intValue) ?? []

            return ChargeLimitState(
                limit: Int(limit),
                enabled: enabled != 0,
                available: steps.isEmpty ? Self.fallbackSteps : steps,
                obcEnabled: obcErr == nil && obc != 0)
        } ?? nil
    }

    /// Sets the cap. 100 releases the limit entirely.
    func set(limit: Int) throws {
        let clamped = UInt8(max(50, min(100, limit)))
        guard let c = client ?? Self.makeClient() else {
            throw NSError(domain: "JuiceBar.ChargeLimit", code: 1, userInfo:
                [NSLocalizedDescriptionKey: "charge-limit service unavailable"])
        }
        client = c
        try c.overrideTarget(clamped)
    }
}
