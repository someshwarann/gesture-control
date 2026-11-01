import Foundation
import IOKit.ps

enum Power {
    /// (on battery?, percent), or nil on a Mac with no battery.
    static func battery() -> (onBattery: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let state = d[kIOPSPowerSourceStateKey] as? String
            return (state == kIOPSBatteryPowerValue, cur * 100 / max)
        }
        return nil
    }

    static var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// True when the battery is low enough that the camera should stay off.
    static var batteryTooLow: Bool {
        guard let b = battery() else { return false }
        return b.onBattery && b.percent < 15
    }
}
