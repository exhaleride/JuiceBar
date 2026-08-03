import Foundation

enum Thermal {
    /// macOS's own thermal-pressure level (public API).
    static var stateName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    /// True when the OS reports pressure worth flagging in the menu bar.
    static var isElevated: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }
}
