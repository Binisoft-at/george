import SwiftUI
import BinisoftKit
import SwiftData
import TipKit
import GeorgeCore

/// Home: what to do now, this week at a glance, how your muscles are doing, and recent workouts.
struct TodayView: View {
    @Environment(GeorgeStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(LiveWorkoutController.self) private var live
    @Environment(HealthKitManager.self) private var health
    @Query private var sessions: [WorkoutSession]
    @Query private var templates: [WorkoutTemplate]
    @AppStorage(Prefs.energyCheckIn) private var energyCheckIn = true

    var body: some View {
        let _ = sessions.count + templates.count + store.revision
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                UpNextCard()
                StreakCard()
                if energyCheckIn {
                    EnergyTodayCard()
                }
                quickActions
                plannedSection
                sectionTitle("Body", symbol: "figure.arms.open")
                MuscleFreshnessCard()
                MuscularLoadCard(openIn: .muscles)
                recentSection
            }
            .padding(.horizontal)
            .padding(.bottom, 28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(BrandBackdrop())
        .navigationTitle("Today")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    router.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            #endif
            ToolbarItem(placement: .georgeTrailing) {
                Button {
                    router.showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create")
                .popoverTip(GeorgeTips.CreateTip())
            }
        }
        .refreshable {
            await health.refresh()
            await health.loadSignals()
            store.bump()
        }
    }

    // MARK: Sections

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            QuickAction(title: "Empty Workout", symbol: "bolt.fill", tint: .accentColor) {
                if live.isActive { live.isPresented = true } else { live.startEmpty(program: store.activeProgram) }
            }
            QuickAction(title: "Plan", symbol: "calendar.badge.plus", tint: .indigo) {
                router.createStep = .plan
                router.showCreate = true
            }
            QuickAction(title: "New Template", symbol: "square.on.square.fill", tint: .orange) {
                router.createStep = .newTemplate
                router.showCreate = true
            }
            QuickAction(title: "Log Past", symbol: "clock.arrow.circlepath", tint: .teal) {
                router.createStep = .logPast
                router.showCreate = true
            }
        }
    }

    @ViewBuilder
    private var plannedSection: some View {
        let planned = store.upcomingSessions(limit: 4)
        if !planned.isEmpty {
            sectionTitle("Planned", symbol: "calendar")
            VStack(spacing: 0) {
                ForEach(Array(planned.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider().padding(.leading, 58) }
                    HStack(spacing: 12) {
                        Button {
                            router.open(.session(session.id))
                        } label: {
                            HStack(spacing: 12) {
                                DayBadge(date: session.plannedDate ?? session.date)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(session.subtitle.isEmpty ? session.summaryLine : session.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            live.start(session)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .disabled(live.isActive)
                        .accessibilityLabel("Start \(session.title)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .card(padding: 0, cornerRadius: 22)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        let recent = sessions
            .filter { $0.status.isPerformed }
            .sorted { $0.date > $1.date }
            .prefix(3)
        if !recent.isEmpty {
            HStack {
                sectionTitle("Recent", symbol: "clock")
                Spacer()
                Button("See All") { router.show(.allSessions) }
                    .font(.subheadline)
            }
            VStack(spacing: 0) {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider().padding(.leading, 56) }
                    Button {
                        router.open(.session(session.id))
                    } label: {
                        SessionRow(session: session)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .card(padding: 0, cornerRadius: 22)
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .padding(.top, 8)
            .padding(.horizontal, 4)
    }
}

private struct QuickAction: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(padding: 0, cornerRadius: 18)
    }
}

/// "FRI / 31" calendar badge.
struct DayBadge: View {
    let date: Date

    var body: some View {
        let isToday = Calendar.current.isDateInToday(date)
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isToday ? Color.white.opacity(0.9) : Color.accentColor)
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(isToday ? Color.white : Color.primary)
        }
        .frame(width: 34, height: 38)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isToday ? Color.accentColor : Color.accentColor.opacity(0.12))
        )
    }
}

/// Grouped background with a soft brand glow at the top (like the app icon).
struct BrandBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            groupedBackground
            RadialGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.32 : 0.16), Color.accentColor.opacity(0)],
                center: .top,
                startRadius: 10,
                endRadius: 460
            )
            .frame(height: 560)
        }
        .ignoresSafeArea()
    }

    private var groupedBackground: Color {
        #if os(iOS)
        return Color(uiColor: .systemGroupedBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }
}
