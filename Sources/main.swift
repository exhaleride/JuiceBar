import AppKit
import ServiceManagement

// JuiceBar — menu bar power in/out/balance + throttle monitor.
// Data: AppleSmartBattery (IOKit) + private IOReport (SoC power & frequency).

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var soc: IOReportSampler?
    private var smc: SMCSampler?
    private var hidTemps: HIDTempSampler?
    private var display: DisplaySampler?
    private let system = SystemSampler()
    private var lastTick = Date()

    // Wall telemetry (SystemPowerIn) refreshes only ~every 30 s, so for a
    // window after (un)plugging the wall/system numbers are stale — hide them
    // rather than show garbage like "system jumped 20→50 W".
    private var lastPlugState: Bool?
    private var plugFlipTime: Date?
    private var menuOpen = false
    private static let settleSeconds: TimeInterval = 35

    // Optional extra bar-title numbers (↓system draw, →time to full/empty).
    // Off by default; toggled from the dropdown, persisted across launches.
    private var barDetail = UserDefaults.standard.bool(forKey: "BarDetail")

    // Charge limit. macOS forgets the chosen cap whenever PowerUIAgent restarts
    // (it is never written to disk), so we keep the choice here and put it back
    // — see ChargeLimit.swift. nil = the feature is unavailable on this Mac.
    private var chargeLimit: ChargeLimit?
    private var limitState: ChargeLimitState?
    private var limitStateAt = Date.distantPast
    private var lastLimitError: String?
    private static let limitRefreshSeconds: TimeInterval = 60

    private var isSettling: Bool {
        guard let t = plugFlipTime else { return false }
        return Date().timeIntervalSince(t) < Self.settleSeconds
    }

    private let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

    func applicationDidFinishLaunching(_ note: Notification) {
        soc = IOReportSampler()
        smc = SMCSampler()
        hidTemps = HIDTempSampler()
        display = DisplaySampler()
        chargeLimit = ChargeLimit()
        refreshChargeLimit(force: true)

        // Launch at login is a permanent setting for this app, so register it
        // here rather than exposing a toggle. register() is idempotent.
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        menu.delegate = self
        statusItem.menu = menu

        // .common so it keeps firing while the menu is open (event-tracking mode)
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    // MARK: - Sampling & rendering

    private func tick() {
        let interval = Date().timeIntervalSince(lastTick)
        lastTick = Date()

        var power = BatterySampler.sample()
        if let last = lastPlugState, last != power.externalConnected {
            plugFlipTime = Date()
        }
        if lastPlugState != power.externalConnected {
            refreshChargeLimit(force: true)   // plugging in is when the cap starts to matter
        }
        lastPlugState = power.externalConnected
        if isSettling {
            // Live values (battery V×I, %) stay; stale-derived ones go.
            power.wallPowerW = nil
        }

        if power.externalConnected { refreshChargeLimit() }
        power.chargeLimit = limitState?.effectiveLimit

        let socSample = soc?.sample(intervalSeconds: max(interval, 0.5)) ?? SocSample()
        statusItem.button?.attributedTitle = menuBarTitle(power, socSample, detailed: barDetail)

        // Net counters are sampled every tick (getifaddrs is cheap) so rates
        // are ready the moment the menu opens instead of after one priming tick.
        let net = system.network()

        // Heavy sensors (temps, fans, display, RAM, disk) and the menu rebuild
        // only run while the menu is open — keeps the idle cost near zero.
        if menuOpen {
            rebuildMenu(power, socSample, net)
        }
    }

    private func rebuildMenu(_ p: PowerSnapshot, _ s: SocSample, _ net: SystemSampler.Network?) {
        menu.removeAllItems()

        func row(_ text: String, bold: Bool = false) {
            let item = NSMenuItem()
            item.attributedTitle = NSAttributedString(
                string: text, attributes: [.font: bold ? monoBold : mono])
            item.isEnabled = false
            menu.addItem(item)
        }
        func watts(_ w: Double?) -> String { w.map { String(format: "%6.1f W", $0) } ?? "     — " }

        // IN — drawn watts vs the negotiated PD contract. A 100 W charger
        // showing 36 W is the Mac drawing what it needs, not a weak charger.
        if p.externalConnected {
            var contract = ""
            if let w = p.adapterMaxW {
                let volts = p.adapterVolts.map { String(format: ", %.0f V", $0) } ?? ""
                contract = "  (contract \(w) W\(volts))"
            }
            if isSettling {
                row("IN    Wall    settling…\(contract)", bold: true)
                row("      wall reading lags ~30 s after (un)plug")
            } else {
                row("IN    Wall    \(watts(p.wallPowerW))\(contract)", bold: true)
            }
        } else {
            row("IN    Wall           0 W  (on battery)", bold: true)
        }

        // OUT
        let disp = display?.sample()
        row("OUT   System    \(watts(p.systemPowerW))", bold: true)
        if let sys = p.systemPowerW, let cpu = s.cpuW {
            let gpu = s.gpuW ?? 0, ane = s.aneW ?? 0
            let rest = max(sys - cpu - gpu - ane, 0)
            row("      ├ CPU     \(watts(cpu))")
            row("      ├ GPU     \(watts(gpu))")
            row("      ├ ANE     \(watts(ane))")
            row("      └ Rest    \(watts(rest))")
            // Identifiable pieces of Rest drawing real power (> 4 W): measured
            // on-chip meters (memory, media, camera, PCIe) + the display
            // backlight estimate. Quiet consumers stay hidden.
            var hungry = s.otherW.filter { $0.watts > 4 }
                .map { (name: $0.name, watts: $0.watts, est: false) }
            if let d = disp, d.estWatts > 4 {
                hungry.append((name: "Display", watts: d.estWatts, est: true))
            }
            for h in hungry.sorted(by: { $0.watts > $1.watts }) {
                row("          · \(h.name)  \(watts(h.watts))\(h.est ? "  (est.)" : "")")
            }
        }

        // NET
        if let batt = p.batteryFlowW {
            let arrow = batt > 0.5 ? "▲" : (batt < -0.5 ? "▼" : "·")
            let sign = batt > 0 ? "+" : ""
            var line = "NET   Battery   \(sign)\(String(format: "%.1f", batt)) W \(arrow)"
            if let pct = p.chargePercent { line += "  \(pct) %" }
            if let mins = p.timeRemainingMin {
                let dest = p.isCharging ? "full" : "empty"
                line += String(format: " → %@ %d:%02d", dest, mins / 60, mins % 60)
            }
            row(line, bold: true)
        }
        if let temp = p.batteryTempC {
            row("      Cell temp  \(String(format: "%5.1f", temp)) °C")
        }

        // Raw measurement chain — answers "where do these numbers come from?"
        let meas = NSMenuItem(title: "Measurement", action: nil, keyEquivalent: "")
        let measMenu = NSMenu()
        func mrow(_ text: String) {
            let item = NSMenuItem()
            item.attributedTitle = NSAttributedString(string: text, attributes: [.font: mono])
            item.isEnabled = false
            measMenu.addItem(item)
        }
        if let w = p.wallPowerW {
            mrow(String(format: "SystemPowerIn (SMC)  %8.0f mW", w * 1000))
        } else {
            mrow("SystemPowerIn (SMC)   stale/settling")
        }
        if let l = p.adapterLossW {
            mrow(String(format: "Adapter cable loss   %8.0f mW", l * 1000))
        }
        if let v = p.batteryVolts, let a = p.batteryAmps {
            mrow(String(format: "Battery V×I  %.2f V × %+.2f A = %+.1f W", v, a, v * a))
        }
        if let w = p.adapterMaxW, let v = p.adapterVolts, let a = p.adapterAmps {
            mrow(String(format: "PD contract  %d W (%.0f V × %.1f A)", w, v, a))
        }
        mrow("system = wall − cable loss − battery flow")
        mrow("wall refreshes ~30 s · battery V×I is live")
        mrow("contract = negotiated max, not actual draw")
        meas.submenu = measMenu
        menu.addItem(meas)

        menu.addItem(.separator())

        // NETWORK — internet down/up rates (battery flow above is labelled NET)
        if let n = net {
            row("NETWORK  ↓ \(SystemSampler.rate(n.downBps)) · ↑ \(SystemSampler.rate(n.upBps))",
                bold: true)
            menu.addItem(.separator())
        }

        // THROTTLE
        row("THROTTLE   Thermal: \(Thermal.stateName)", bold: true)
        func freqRow(_ label: String, _ f: Double?, _ m: Double?, _ active: Double?) {
            guard let f, let m, m > 0 else { return }
            let pct = Int((f / m * 100).rounded())
            let busy = active.map { String(format: "  busy %3.0f %%", $0 * 100) } ?? ""
            row(String(format: "%@ %4.2f / %4.2f GHz  %3d %%%@", label, f / 1000, m / 1000, pct, busy))
        }
        freqRow("P-cores  ", s.pFreqMHz, s.pMaxMHz, s.pActive)
        freqRow("E-cores  ", s.eFreqMHz, s.eMaxMHz, s.eActive)
        freqRow("GPU      ", s.gpuFreqMHz, s.gpuMaxMHz, s.gpuActive)
        if s.pFreqMHz == nil && s.gpuFreqMHz == nil {
            row("(SoC frequency data unavailable)")
        }

        // TEMPS + FANS
        let curated = hidTemps?.curated()
        let allTemps = hidTemps?.all() ?? []
        let fans = smc?.fans() ?? []
        if curated != nil || !fans.isEmpty {
            menu.addItem(.separator())
        }
        if let c = curated {
            func deg(_ v: Double) -> String { String(format: "%.0f°", v) }
            var parts: [String] = []
            if let v = c.cpu { parts.append("SoC \(deg(v))") }
            if let v = c.gpu { parts.append("GPU \(deg(v))") }
            if let v = c.battery ?? p.batteryTempC { parts.append("Batt \(deg(v))") }
            if let v = c.ssd { parts.append("SSD \(deg(v))") }
            row("TEMPS  \(parts.joined(separator: " · "))", bold: true)
            if !allTemps.isEmpty {
                let parent = NSMenuItem(title: "All sensors", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for t in allTemps {
                    let item = NSMenuItem()
                    item.attributedTitle = NSAttributedString(
                        string: String(format: "%-28s %6.1f °C",
                                       (t.name as NSString).utf8String!, t.celsius),
                        attributes: [.font: mono])
                    item.isEnabled = false
                    sub.addItem(item)
                }
                parent.submenu = sub
                menu.addItem(parent)
            }
        }
        if !fans.isEmpty {
            if fans.allSatisfy({ !$0.isRunning }) {
                row("FANS   off", bold: true)
            } else {
                let list = fans.enumerated()
                    .map { i, f in "\(i == 0 ? "Left" : "Right") \(Int(f.rpm.rounded()))" }
                    .joined(separator: " · ")
                row("FANS   \(list) RPM", bold: true)
            }
        }

        // SYS: brightness, RAM, network
        menu.addItem(.separator())
        if let d = disp {
            row(String(format: "SYS    Display %.0f %% (≈%d nits)",
                       d.percent * 100, Int(d.estNits.rounded())), bold: true)
        }
        if let m = system.memory() {
            let used = Double(m.usedBytes) / 1_073_741_824
            let total = Double(m.totalBytes) / 1_073_741_824
            row(String(format: "       RAM %.1f / %.0f GB · pressure %@", used, total, m.pressure))
        }
        if let st = system.storage() {
            if st.swapTotalBytes > 0 {
                row(String(format: "       Swap %.1f / %.1f GB on SSD",
                           Double(st.swapUsedBytes) / 1_073_741_824,
                           Double(st.swapTotalBytes) / 1_073_741_824))
            } else {
                row("       Swap off")
            }
            // Decimal GB to match Finder / the sticker on the box.
            let du = Double(st.diskUsedBytes) / 1_000_000_000
            let dt = Double(st.diskTotalBytes) / 1_000_000_000
            row(String(format: "       SSD  %.0f / %.0f GB (%d %% full)",
                       du, dt, Int((du / dt * 100).rounded())))
        }

        // CHARGE LIMIT — hidden entirely on Macs without a manual charge limit.
        if chargeLimit != nil, let st = limitState {
            menu.addItem(.separator())
            row("CHARGE LIMIT   \(limitStatus(p, st))", bold: true)
            if let err = lastLimitError { row("       ⚠︎ \(err)") }
            for step in st.available {
                let item = NSMenuItem(title: step >= 100 ? "100 %  (no limit)" : "\(step) %",
                                      action: #selector(selectChargeLimit(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = step
                item.indentationLevel = 1
                let active = st.enabled ? st.limit : 100
                item.state = (step == active) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Show draw & time in menu bar",
                                action: #selector(toggleBarDetail), keyEquivalent: "")
        toggle.target = self
        toggle.state = barDetail ? .on : .off
        menu.addItem(toggle)

        menu.addItem(NSMenuItem(title: "Quit JuiceBar",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleBarDetail() {
        barDetail.toggle()
        UserDefaults.standard.set(barDetail, forKey: "BarDetail")
        tick()   // refresh the bar title immediately
    }

    // MARK: - Charge limit

    private static let limitKey = "ChargeLimit"

    /// Reads the cap from macOS, and puts our remembered value back if the two
    /// have drifted apart — which happens whenever PowerUIAgent restarts, since
    /// the override is never persisted. Cheap (well under a millisecond over
    /// XPC), but still throttled: forced on launch, menu open, plug events and
    /// after every click, otherwise once a minute while on the charger.
    private func refreshChargeLimit(force: Bool = false) {
        guard let cl = chargeLimit else { return }
        guard force || Date().timeIntervalSince(limitStateAt) >= Self.limitRefreshSeconds else { return }
        limitStateAt = Date()

        guard var st = cl.state() else { limitState = nil; return }
        let defaults = UserDefaults.standard

        guard let desired = defaults.object(forKey: Self.limitKey) as? Int else {
            // First launch: adopt whatever macOS is already doing rather than
            // silently changing the user's battery behaviour.
            defaults.set(st.enabled ? st.limit : 100, forKey: Self.limitKey)
            limitState = st
            return
        }

        let observed = st.enabled ? st.limit : 100
        if observed != desired, st.available.contains(desired) {
            if (try? cl.set(limit: desired)) != nil, let reread = cl.state() { st = reread }
        }
        limitState = st
    }

    private func limitStatus(_ p: PowerSnapshot, _ st: ChargeLimitState) -> String {
        guard let cap = st.effectiveLimit else { return "off — charges to 100 %" }
        if !p.externalConnected { return "\(cap) % (on battery)" }
        if p.isCharging { return "charging to \(cap) %" }
        if let pct = p.chargePercent, pct > cap { return "above \(cap) % — draining to it" }
        return "held at \(cap) %"
    }

    @objc private func selectChargeLimit(_ sender: NSMenuItem) {
        guard let step = sender.representedObject as? Int, let cl = chargeLimit else { return }
        do {
            try cl.set(limit: step)
            UserDefaults.standard.set(step, forKey: Self.limitKey)
            lastLimitError = nil
        } catch {
            let e = error as NSError
            lastLimitError = "couldn't set \(step) % (\(e.domain) \(e.code))"
        }
        refreshChargeLimit(force: true)
        tick()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        refreshChargeLimit(force: true)
        tick()
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon (belt & braces with LSUIElement)
app.run()
