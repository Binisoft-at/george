import Foundation
import BinisoftKit
import GeorgeCore
#if os(iOS)
import HealthKit
#endif

/// Recovery signals and history from Apple Health: HRV, resting heart rate and sleep per day,
/// State of Mind entries as energy history, and the birth year.
extension HealthKitManager {
    /// Year of birth from Apple Health (asks for access to it first), nil when not set or not allowed.
    func birthYear() async -> Int? {
        #if os(iOS)
        guard isAvailable else { return nil }
        try? await healthStore.requestAuthorization(toShare: [], read: [HKCharacteristicType(.dateOfBirth)])
        return (try? healthStore.dateOfBirthComponents())?.year
        #else
        return nil
        #endif
    }

    /// Loads daily HRV, resting heart rate and sleep and works out today's readiness.
    func loadSignals(days: Int = 120) async {
        #if os(iOS)
        guard isAvailable, CoachPrefs.healthSignals else {
            healthSignals = []
            readiness = nil
            return
        }
        let calendar = Calendar.current
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: end)) ?? end
        async let hrv = dailyAverage(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: start, to: end)
        async let resting = dailyAverage(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end)
        async let sleep = dailySleep(from: start, to: end)
        let (hrvByDay, restingByDay, sleepByDay) = await (hrv, resting, sleep)
        let days = Set(hrvByDay.keys).union(restingByDay.keys).union(sleepByDay.keys)
        healthSignals = days.sorted().map {
            DailyHealthSignal(day: $0, hrvMs: hrvByDay[$0], restingHeartRate: restingByDay[$0], sleepHours: sleepByDay[$0])
        }
        readiness = BodyReadiness.evaluate(healthSignals, now: end, calendar: calendar)
        AppLog.info("Health signals: \(healthSignals.count) days", category: "health")
        #endif
    }

    /// "State of Mind" entries logged in the Health app, as energy levels (oldest first).
    func moodHistory(days: Int = 365) async -> [EnergyEntry] {
        #if os(iOS)
        guard isAvailable else { return [] }
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: HKObjectType.stateOfMindType(), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)],
            limit: 3000
        )
        do {
            let samples = try await descriptor.result(for: healthStore)
            return samples.compactMap { $0 as? HKStateOfMind }.map {
                EnergyEntry(date: $0.startDate, level: EnergyEntry.level(fromValence: $0.valence))
            }
        } catch {
            AppLog.warning("State of Mind: \(error.localizedDescription)", category: "health")
            return []
        }
        #else
        return []
        #endif
    }

    #if os(iOS)
    private func dailyAverage(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date) async -> [Date: Double] {
        let calendar = Calendar.current
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(id), predicate: predicate),
            options: .discreteAverage,
            anchorDate: calendar.startOfDay(for: start),
            intervalComponents: DateComponents(day: 1)
        )
        guard let collection = try? await descriptor.result(for: healthStore) else { return [:] }
        var result: [Date: Double] = [:]
        for statistics in collection.statistics() {
            if let quantity = statistics.averageQuantity() {
                result[calendar.startOfDay(for: statistics.startDate)] = quantity.doubleValue(for: unit)
            }
        }
        return result
    }

    /// Hours asleep per night, credited to the day the sleep ended. When several devices recorded
    /// the same night, the one with the most sleep counts (no double counting).
    private func dailySleep(from start: Date, to end: Date) async -> [Date: Double] {
        let calendar = Calendar.current
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)],
            limit: nil
        )
        guard let samples = try? await descriptor.result(for: healthStore) else { return [:] }
        var bySource: [Date: [String: Double]] = [:]
        for sample in samples {
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                  HKCategoryValueSleepAnalysis.allAsleepValues.contains(value) else { continue }
            let day = calendar.startOfDay(for: sample.endDate)
            let source = sample.sourceRevision.source.bundleIdentifier
            bySource[day, default: [:]][source, default: 0] += sample.endDate.timeIntervalSince(sample.startDate) / 3600
        }
        return bySource.compactMapValues { $0.values.max() }
    }
    #endif
}
