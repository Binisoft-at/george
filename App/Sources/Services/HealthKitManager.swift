import Foundation
import Observation
import BinisoftKit
import GeorgeCore
#if os(iOS)
import HealthKit
#endif

/// Everything George exchanges with Apple Health.
///
/// Writes: the workout (activity type per kind, duration, active energy, metadata with the
/// exercises and muscles), and the workout effort score (RPE 1–10) — Apple Fitness shows it and
/// Bevel reads it for strain. Heart rate comes from the Apple Watch app's live workout session.
///
/// Reads: workouts from other apps/devices (e.g. tennis tracked on the watch) – kept in memory
/// only, they count toward the weekly streak, Insights → Time by type and (Settings) muscle
/// recovery and load – heart rate during a session, and body mass for calorie estimates. With
/// Settings → Workout Coach → Health signals on, also HRV, resting heart rate, sleep and State of
/// Mind (energy insights, the check-in hint) and the birth date (Your Profile, on request).
@MainActor
@Observable
final class HealthKitManager {
    struct SaveRequest {
        var sessionID: UUID
        var title: String
        var kind: WorkoutKind
        var start: Date
        var end: Date
        var activeSeconds: Double
        var energyKcal: Double
        var effort: Int
        var exercises: [String]
        var muscles: [String]
        var completedSets: Int
        var volumeKg: Double
    }

    struct HeartRateSummary {
        var average: Double
        var max: Double
    }

    /// Apple Health workouts from other apps and devices (last ~26 weeks, newest first). In memory
    /// only – Health data never goes to iCloud.
    private(set) var healthWorkouts: [ExternalWorkout] = []
    /// Bumped whenever `healthWorkouts` changes (the muscle analytics cache key).
    private(set) var workoutsVersion = 0
    /// The same workouts as streak entries.
    private(set) var externalWorkouts: [ActivityEntry] = []
    /// Effort scores already read, per Health workout (nil = none recorded).
    @ObservationIgnored private var effortCache: [UUID: Int?] = [:]
    private(set) var latestBodyMassKg: Double?
    private(set) var lastError: String?
    private(set) var isAuthorizedToShare = false
    /// Daily HRV, resting heart rate and sleep (last ~4 months), for the energy insights.
    var healthSignals: [DailyHealthSignal] = []
    /// Today's recovery signals against the usual (nil without Health data).
    var readiness: BodyReadiness?

    #if os(iOS)
    let healthStore = HKHealthStore()
    #endif

    var isAvailable: Bool {
        #if os(iOS)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    #if os(iOS)
    private var shareTypes: Set<HKSampleType> {
        [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.workoutEffortScore),
        ]
    }

    private var readTypes: Set<HKObjectType> {
        [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.bodyMass),
            HKQuantityType(.workoutEffortScore),
            HKQuantityType(.estimatedWorkoutEffortScore),
            // Energy & recovery (Insights → Energy, the workout check-in).
            HKCharacteristicType(.dateOfBirth),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKCategoryType(.sleepAnalysis),
            HKObjectType.stateOfMindType(),
        ]
    }
    #endif

    func requestAuthorization() async {
        #if os(iOS)
        guard isAvailable else { return }
        do {
            try await healthStore.requestAuthorization(toShare: shareTypes, read: readTypes)
            isAuthorizedToShare = healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
            await refresh()
        } catch {
            lastError = error.localizedDescription
            AppLog.warning("Apple Health: \(error.localizedDescription)", category: "health")
        }
        #endif
    }

    /// Loads external workouts (last ~26 weeks) and the latest body mass.
    func refresh() async {
        #if os(iOS)
        guard isAvailable else { return }
        isAuthorizedToShare = healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        let since = Calendar.current.date(byAdding: .day, value: -182, to: Date()) ?? Date()
        let ownPrefix = Bundle.main.bundleIdentifier ?? "george"
        do {
            let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.workout(predicate)],
                sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
                limit: 1000
            )
            let workouts = try await descriptor.result(for: healthStore)
                .filter { !Self.isFromGeorge($0, ownPrefix: ownPrefix) }
            // Effort only matters for recent workouts (muscle load looks back 6 weeks).
            let effortCutoff = Date().addingTimeInterval(-42 * 86_400)
            for workout in workouts.prefix(80) where workout.startDate >= effortCutoff && effortCache[workout.uuid] == nil {
                effortCache[workout.uuid] = .some(await effort(of: workout))
            }
            let mapped = workouts.map { workout -> ExternalWorkout in
                let sport = Self.sport(for: workout.workoutActivityType)
                let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                return ExternalWorkout(
                    id: workout.uuid, activity: sport.key, name: sport.name, start: workout.startDate,
                    durationSeconds: workout.duration, energyKcal: energy, effort: effortCache[workout.uuid] ?? nil
                )
            }
            setHealthWorkouts(mapped)
        } catch {
            lastError = error.localizedDescription
            AppLog.warning("Apple Health: \(error.localizedDescription)", category: "health")
        }
        do {
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: HKQuantityType(.bodyMass))],
                sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
                limit: 1
            )
            if let sample = try await descriptor.result(for: healthStore).first {
                latestBodyMassKg = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
            }
        } catch {
            // Body mass is optional.
        }
        #endif
    }

    /// Keeps the Health workouts and derives the streak entries from them.
    private func setHealthWorkouts(_ workouts: [ExternalWorkout]) {
        if workouts != healthWorkouts {
            healthWorkouts = workouts
            workoutsVersion &+= 1
        }
        externalWorkouts = workouts.map {
            ActivityEntry(date: $0.start, minutes: $0.durationSeconds / 60, isRescue: false, source: .health)
        }
    }

    /// Average / max heart rate recorded (by any device) during a time window.
    func heartRate(from start: Date, to end: Date) async -> HeartRateSummary? {
        #if os(iOS)
        guard isAvailable, end > start else { return nil }
        let type = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: [.discreteAverage, .discreteMax]
        )
        guard let stats = try? await descriptor.result(for: healthStore) else { return nil }
        let unit = HKUnit.count().unitDivided(by: .minute())
        guard let avg = stats.averageQuantity()?.doubleValue(for: unit) else { return nil }
        let max = stats.maximumQuantity()?.doubleValue(for: unit) ?? avg
        return HeartRateSummary(average: avg, max: max)
        #else
        return nil
        #endif
    }

    /// Saves a finished George session as an HKWorkout. Returns the workout UUID.
    func saveWorkout(_ request: SaveRequest) async -> UUID? {
        #if os(iOS)
        guard isAvailable else { return nil }
        let configuration = request.kind.healthConfiguration()
        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration, device: .local())
        let end = max(request.end, request.start.addingTimeInterval(60))
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                builder.beginCollection(withStart: request.start) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            if request.energyKcal > 0 {
                let energy = HKQuantitySample(
                    type: HKQuantityType(.activeEnergyBurned),
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: request.energyKcal),
                    start: request.start,
                    end: end
                )
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    builder.add([energy]) { _, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
            var metadata: [String: Any] = [
                HKMetadataKeyIndoorWorkout: configuration.locationType != .outdoor,
                HKMetadataKeyWorkoutBrandName: "George",
                HealthMetadataKey.sessionID: request.sessionID.uuidString,
                HealthMetadataKey.workoutTitle: request.title,
                HealthMetadataKey.completedSets: Double(request.completedSets),
            ]
            if !request.exercises.isEmpty {
                metadata[HealthMetadataKey.exercises] = String(request.exercises.joined(separator: ", ").prefix(900))
            }
            if !request.muscles.isEmpty {
                metadata[HealthMetadataKey.muscles] = request.muscles.joined(separator: ", ")
            }
            if request.volumeKg > 0 {
                metadata[HealthMetadataKey.volumeKg] = request.volumeKg
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                builder.addMetadata(metadata) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                builder.endCollection(withEnd: end) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            let workout: HKWorkout? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKWorkout?, Error>) in
                builder.finishWorkout { workout, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: workout) }
                }
            }
            guard let workout else { return nil }
            if request.effort > 0 {
                await relateEffort(request.effort, to: workout)
            }
            return workout.uuid
        } catch {
            lastError = error.localizedDescription
            AppLog.warning("Apple Health: \(error.localizedDescription)", category: "health")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Attach an effort score to a workout recorded elsewhere (e.g. by the watch app).
    func relateEffort(_ effort: Int, toWorkoutWithID id: UUID) async {
        #if os(iOS)
        guard isAvailable, effort > 0 else { return }
        let predicate = HKQuery.predicateForObject(with: id)
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [], limit: 1)
        guard let workout = try? await descriptor.result(for: healthStore).first else { return }
        await relateEffort(effort, to: workout)
        #endif
    }

    #if os(iOS)
    private func relateEffort(_ effort: Int, to workout: HKWorkout) async {
        let sample = HKQuantitySample(
            type: HKQuantityType(.workoutEffortScore),
            quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: Double(max(1, min(10, effort)))),
            start: workout.startDate,
            end: workout.endDate
        )
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                healthStore.relateWorkoutEffortSample(sample, with: workout, activity: nil) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            lastError = error.localizedDescription
            AppLog.warning("Apple Health: \(error.localizedDescription)", category: "health")
        }
    }

    /// Workouts George saved itself (this app or its watch app) – they are already in the log.
    private static func isFromGeorge(_ workout: HKWorkout, ownPrefix: String) -> Bool {
        if workout.sourceRevision.source.bundleIdentifier.hasPrefix(ownPrefix) { return true }
        return workout.metadata?[HealthMetadataKey.sessionID] != nil
    }

    /// The effort score (1–10) rated for a workout, or Apple's estimate, if any.
    private func effort(of workout: HKWorkout) async -> Int? {
        let predicate = HKQuery.predicateForWorkoutEffortSamplesRelated(workout: workout, activity: nil)
        for type in [HKQuantityType(.workoutEffortScore), HKQuantityType(.estimatedWorkoutEffortScore)] {
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: type, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
                limit: 1
            )
            if let sample = try? await descriptor.result(for: healthStore).first {
                let value = sample.quantity.doubleValue(for: .appleEffortScore())
                if value > 0 { return max(1, min(10, Int(value.rounded()))) }
            }
        }
        return nil
    }

    /// The sport key (`SportLoad`) and display name of a Health activity type.
    static func sport(for type: HKWorkoutActivityType) -> (key: String, name: String) {
        switch type {
        case .tennis: return ("tennis", "Tennis")
        case .squash: return ("squash", "Squash")
        case .badminton: return ("badminton", "Badminton")
        case .tableTennis: return ("table-tennis", "Table Tennis")
        case .racquetball: return ("racquetball", "Racquetball")
        case .pickleball: return ("pickleball", "Pickleball")
        case .running: return ("running", "Running")
        case .trackAndField: return ("running", "Track & Field")
        case .cycling, .handCycling: return ("cycling", "Cycling")
        case .hiking: return ("hiking", "Hiking")
        case .walking: return ("walking", "Walking")
        case .highIntensityIntervalTraining: return ("hiit", "HIIT")
        case .functionalStrengthTraining: return ("functional-strength", "Functional Strength")
        case .crossTraining: return ("cross-training", "Cross Training")
        case .swimming: return ("swimming", "Swimming")
        case .rowing: return ("rowing", "Rowing")
        case .soccer: return ("soccer", "Soccer")
        case .americanFootball, .australianFootball: return ("football", "Football")
        case .basketball: return ("basketball", "Basketball")
        case .volleyball: return ("volleyball", "Volleyball")
        case .handball: return ("handball", "Handball")
        case .hockey: return ("hockey", "Hockey")
        case .rugby: return ("rugby", "Rugby")
        case .climbing: return ("climbing", "Climbing")
        case .downhillSkiing: return ("skiing", "Skiing")
        case .crossCountrySkiing: return ("skiing", "Cross-Country Skiing")
        case .snowboarding: return ("snowboarding", "Snowboarding")
        case .boxing: return ("boxing", "Boxing")
        case .kickboxing: return ("kickboxing", "Kickboxing")
        case .martialArts: return ("martial-arts", "Martial Arts")
        case .wrestling: return ("martial-arts", "Wrestling")
        case .socialDance, .cardioDance: return ("dance", "Dance")
        case .yoga: return ("yoga", "Yoga")
        case .pilates, .barre: return ("pilates", "Pilates")
        case .mindAndBody, .taiChi: return ("mind-and-body", "Mind & Body")
        case .flexibility: return ("stretching", "Stretching")
        case .preparationAndRecovery, .cooldown: return ("mobility", "Recovery")
        case .traditionalStrengthTraining: return ("strength", "Strength Training")
        case .coreTraining: return ("core", "Core Training")
        case .mixedCardio, .elliptical, .stairClimbing, .stairs, .stepTraining, .jumpRope: return ("cardio", "Cardio")
        case .golf: return ("golf", "Golf")
        default: return ("other", "Workout")
        }
    }

    /// Launch the watch app with a workout configuration so it starts recording heart rate.
    func startWatchWorkout(kind: WorkoutKind) {
        guard isAvailable else { return }
        healthStore.startWatchApp(with: kind.healthConfiguration()) { _, _ in }
    }
    #endif
}
