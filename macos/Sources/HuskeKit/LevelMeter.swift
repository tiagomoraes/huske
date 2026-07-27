// Meter display math. Snapshots arrive at ~8 Hz; the UI renders at display
// rate, so the displayed level approaches the target exponentially (fast
// attack, slower release) and a peak-hold tick rides above it.

import Foundation

public enum MeterScale {
    /// Same mapping as the TUI: -60 dBFS → 0, 0 dBFS → 1.
    public static func normalize(db: Double) -> Double {
        min(1.0, max(0.0, (db + 60.0) / 60.0))
    }

    /// Zone for coloring: green below -18 dB, yellow to -6 dB, red above.
    public enum Zone: Equatable { case quiet, loud, hot }

    public static func zone(db: Double) -> Zone {
        if db > -6 { return .hot }
        if db > -18 { return .loud }
        return .quiet
    }
}

public struct SmoothedMeter: Sendable, Equatable {
    public private(set) var level: Double = 0 // displayed, 0…1
    public private(set) var peak: Double = 0 // peak-hold, 0…1
    private var lastUpdate: Date?
    private var peakSetAt: Date?

    private let attackTau: Double
    private let releaseTau: Double
    private let peakHoldSeconds: Double
    private let peakDecayPerSecond: Double

    public init(
        attackTau: Double = 0.06,
        releaseTau: Double = 0.35,
        peakHoldSeconds: Double = 1.2,
        peakDecayPerSecond: Double = 0.8
    ) {
        self.attackTau = attackTau
        self.releaseTau = releaseTau
        self.peakHoldSeconds = peakHoldSeconds
        self.peakDecayPerSecond = peakDecayPerSecond
    }

    public mutating func step(targetDb: Double, now: Date) {
        let target = MeterScale.normalize(db: targetDb)
        let dt = lastUpdate.map { now.timeIntervalSince($0) } ?? .infinity
        lastUpdate = now

        if dt == .infinity || dt <= 0 {
            level = target
        } else {
            let tau = target > level ? attackTau : releaseTau
            let alpha = 1 - exp(-dt / tau)
            level += (target - level) * alpha
        }

        if level >= peak {
            peak = level
            peakSetAt = now
        } else if let setAt = peakSetAt, dt != .infinity {
            let held = now.timeIntervalSince(setAt)
            if held > peakHoldSeconds {
                peak = max(level, peak - peakDecayPerSecond * dt)
            }
        } else {
            peak = level
            peakSetAt = now
        }
    }

    public mutating func reset() {
        level = 0
        peak = 0
        lastUpdate = nil
        peakSetAt = nil
    }
}
