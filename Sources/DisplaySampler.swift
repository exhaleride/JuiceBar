import CoreGraphics
import Darwin
import Foundation

/// Built-in display brightness.
///
/// macOS 26 exposes NO live measured-nits value to userspace — the IORegistry
/// `BrightnessMilliNits` (AppleARMBacklight), CoreDisplay linear brightness,
/// NVRAM `backlight-nits`, and CoreBrightness diag are all frozen or
/// root-gated (verified empirically 2026-07-29 by sweeping the slider). The
/// live source that works is DisplayServicesGetBrightness (slider position,
/// 0…1). Nits are therefore an ESTIMATE: slider → luminance via gamma 2.2,
/// scaled by the panel's 500-nit SDR maximum (14" MBP XDR spec).
final class DisplaySampler {

    struct Reading {
        var estNits: Double
        var percent: Double    // 0…1 slider position (exact)
        var estWatts: Double   // backlight estimate — see sample()
    }

    private typealias GetBrightnessFn =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private let getBrightness: GetBrightnessFn
    private static let sdrMaxNits = 500.0

    init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW),
            let sym = dlsym(handle, "DisplayServicesGetBrightness")
        else { return nil }
        getBrightness = unsafeBitCast(sym, to: GetBrightnessFn.self)
    }

    func sample() -> Reading? {
        var slider: Float = 0
        guard getBrightness(CGMainDisplayID(), &slider) == 0, slider >= 0, slider <= 1
        else { return nil }
        let s = Double(slider)
        let lum = pow(s, 2.2)   // slider → relative luminance
        // Backlight watts scale ~linearly with luminance: ~0.3 W floor,
        // ~6 W at full 500-nit SDR (14" MBP review measurements). Estimate only.
        return Reading(estNits: Self.sdrMaxNits * lum, percent: s,
                       estWatts: 0.3 + 5.7 * lum)
    }
}
