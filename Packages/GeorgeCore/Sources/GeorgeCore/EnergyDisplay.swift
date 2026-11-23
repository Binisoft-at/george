import Foundation

/// The calories George shows for a workout: Apple Health's measured value when this device has one
/// (Watch-recorded workouts), else George's own estimate (MET × body weight × time), marked "≈" so
/// the two are never mixed up. Measured values stay on the device (docs/HEALTH.md).
public struct EnergyDisplay: Equatable, Sendable {
    public var kcal: Double
    public var isMeasured: Bool

    public init(kcal: Double, isMeasured: Bool) {
        self.kcal = kcal
        self.isMeasured = isMeasured
    }

    /// The value to show: measured when there is one, else the estimate; nil when neither is known.
    public static func choose(measured: Double?, estimated: Double) -> EnergyDisplay? {
        if let measured, measured > 0 { return EnergyDisplay(kcal: measured, isMeasured: true) }
        if estimated > 0 { return EnergyDisplay(kcal: estimated, isMeasured: false) }
        return nil
    }

    /// "406" or "≈318" (an estimate).
    public var number: String {
        (isMeasured ? "" : "≈") + String(Int(kcal.rounded()))
    }

    /// "406 kcal" or "≈318 kcal".
    public var text: String { number + " kcal" }

    /// The same, `fraction` of the way (count-up animations).
    public func text(scaled fraction: Double) -> String {
        (isMeasured ? "" : "≈") + String(Int((kcal * fraction).rounded())) + " kcal"
    }
}
