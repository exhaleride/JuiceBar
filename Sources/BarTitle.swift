import AppKit

/// The menu bar title, e.g. `91% +15 ⌁78` — or, with `detailed`,
/// `91% +15 ⌁78 ↓60 →2:03`.
///
///   91%    battery charge, coloured by state
///   +15    net watts into (+) or out of (−) the battery
///   ⌁78    watts arriving from the wall  (omitted on battery)
///   ↓60    watts the system is drawing        (detailed only)
///   →2:03  time to full / empty               (detailed only)
func menuBarTitle(_ p: PowerSnapshot, _ s: SocSample, detailed: Bool) -> NSAttributedString {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    let title = NSMutableAttributedString()

    if let pct = p.chargePercent {
        title.append(NSAttributedString(
            string: "\(pct)%",
            attributes: [.font: font, .foregroundColor: batteryColour(p)]))
    }

    var parts: [String] = []

    // Net flow. Sub-0.5 W is noise around a settled battery — show nothing.
    if let batt = p.batteryFlowW, abs(batt) >= 0.5 {
        parts.append(String(format: "%+d", Int(batt.rounded())))
    }
    if p.externalConnected, let wall = p.wallPowerW {
        parts.append("⌁\(Int(wall.rounded()))")
    }
    if detailed {
        if let sys = p.systemPowerW {
            parts.append("↓\(Int(sys.rounded()))")
        }
        if let mins = p.timeRemainingMin {
            parts.append(String(format: "→%d:%02d", mins / 60, mins % 60))
        }
    }
    if Thermal.isElevated || (s.worstFreqRatio ?? 1.0) < 0.80 {
        parts.append("⚠︎")
    }

    if !parts.isEmpty {
        title.append(NSAttributedString(
            string: (title.length > 0 ? " " : "") + parts.joined(separator: " "),
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
    }
    if title.length == 0 {
        title.append(NSAttributedString(string: "⌁–", attributes: [.font: font]))
    }
    return title
}

/// Green while charging, blue while held at the charge limit; otherwise
/// red < 10 %, orange 10–20 %, neutral above.
func batteryColour(_ p: PowerSnapshot) -> NSColor {
    if p.isCharging { return .systemGreen }
    // Plugged in and not charging reads as a fault unless you can see it's
    // on purpose — blue says "the cap is doing this".
    if p.heldAtLimit { return .systemBlue }
    if let pct = p.chargePercent {
        if pct < 10 { return .systemRed }
        if pct <= 20 { return .systemOrange }
    }
    return .labelColor
}
