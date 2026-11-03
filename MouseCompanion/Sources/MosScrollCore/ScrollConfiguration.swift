// CC BY-NC 4.0. Mos-derived component; see LICENSE and UPSTREAM.md.
import Foundation

public struct ScrollConfiguration: Codable, Equatable {
    public var enabled = false
    public var smoothVertical = true
    public var smoothHorizontal = true
    public var reverseVertical = false
    public var reverseHorizontal = false
    // Mos OPTIONS_SCROLL_DEFAULT at the pinned revision.
    public var step = 33.6
    public var speed = 2.70
    public var duration = 4.35
    public var excludedApps: [String] = []
    public init() {}

    public mutating func normalize() {
        step = step.isFinite ? min(100, max(1, step)) : 33.6
        speed = speed.isFinite ? min(5, max(0.5, speed)) : 2.7
        duration = duration.isFinite ? min(5, max(1, duration)) : 4.35
        excludedApps = Array(Set(excludedApps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
    }

    /// Adapted from Mos OPTIONS_SCROLL_DEFAULT.generateDurationTransition.
    public var transition: Double { (1000 * (1 - sqrt(duration / 5.2))).rounded() / 1000 }
}
