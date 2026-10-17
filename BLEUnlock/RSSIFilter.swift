import Foundation

/// Smoothing and validation for BLE RSSI samples.
///
/// Raw Bluetooth RSSI is noisy (multipath fading, single-packet outliers),
/// and advertisements arrive at very different rates in passive (~10Hz) vs
/// active-polling (~0.5Hz) mode. The filter therefore smooths over *time*
/// (exponential moving average) instead of over a fixed sample count, so both
/// modes get the same responsiveness. Single-packet spikes are clamped so one
/// outlier can't swing the estimate and flap the lock/unlock decision.
///
/// The average is asymmetric (fast attack, slow release): approaching the
/// device confirms in ~0.3s so unlock doesn't feel laggy, while walking away
/// stays heavily smoothed so a single deep fade can't trigger the lock timer.
struct RSSIFilter {
    /// Time constant when the signal is getting stronger (approaching).
    /// Short: 2-3 consecutive strong packets are enough to confirm.
    static let attackTimeConstant = 0.5
    /// Time constant when the signal is getting weaker (walking away).
    /// Long: single-packet fades are absorbed, lock decisions stay stable.
    static let releaseTimeConstant = 2.0
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

    /// Plausible range for advertised TxPower, in dBm.
    static let validTxPowerRange = -100...30

    /// Rough distance estimate in meters (log-distance path loss model).
    /// Display-only: indoor multipath makes this a trend indicator, not a
    /// measurement — never feed it to lock/unlock decisions.
    static func distance(txPower: Int, rssi: Int, pathExponent: Double = 2.0) -> Double {
        return pow(10.0, Double(txPower - rssi) / (10.0 * pathExponent))
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
            let timeConstant = sample >= current
                ? RSSIFilter.attackTimeConstant
                : RSSIFilter.releaseTimeConstant
            let alpha = 1.0 - exp(-dt / timeConstant)
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
