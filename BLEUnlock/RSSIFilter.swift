import Foundation

/// Smoothing and validation for BLE RSSI samples.
///
/// Raw Bluetooth RSSI is noisy (multipath fading, single-packet outliers),
/// and advertisements arrive at very different rates in passive (~10Hz) vs
/// active-polling (~0.5Hz) mode. The filter therefore smooths over *time*
/// (exponential moving average) instead of over a fixed sample count, so both
/// modes get the same responsiveness. Single-packet spikes are clamped so one
/// outlier can't swing the estimate and flap the lock/unlock decision.
struct RSSIFilter {
    /// Time constant of the moving average, in seconds.
    static let timeConstant = 2.0
    /// Maximum believable jump between the estimate and a new sample, in dB.
    /// Larger jumps are clamped (single-packet fades/spikes).
    static let maxJump = 15.0
    /// Hardware occasionally reports bogus values; only this range is real.
    /// In particular, positive values must never pass: 0dBm would read as
    /// "closer than any unlock threshold" and cause a spurious unlock.
    static let validRange = -100...0

    static func isValidSample(_ rssi: Int) -> Bool {
        return validRange.contains(rssi)
    }

    private(set) var estimate: Double?
    private var lastSampleAt: TimeInterval = 0

    mutating func addSample(_ rssi: Int, at now: TimeInterval = Date().timeIntervalSince1970) -> Int {
        var sample = Double(rssi)
        if let current = estimate {
            let jump = sample - current
            if abs(jump) > RSSIFilter.maxJump {
                sample = current + (jump > 0 ? RSSIFilter.maxJump : -RSSIFilter.maxJump)
            }
            let dt = max(now - lastSampleAt, 0)
            let alpha = 1.0 - exp(-dt / RSSIFilter.timeConstant)
            estimate = current + alpha * (sample - current)
        } else {
            estimate = sample
        }
        lastSampleAt = now
        return Int(estimate!)
    }

    mutating func reset() {
        estimate = nil
        lastSampleAt = 0
    }
}
