import Foundation
import Testing
@testable import BinisoftKitCore

/// A practice page as the tour sees it.
private struct Page: Equatable {
    var items = 3
    var done = 0
    var deleted = 0
    var order = ["a", "b", "c"]
    var editorOpen = false
}

/// Version 1 has three steps; version 2 adds two.
private func catalog(version: Int = 2) -> TourCatalog<Page> {
    let all: [TourStep<Page>] = [
        TourStep(id: "add", symbol: "plus", title: "Add", body: "Add one.", goal: .increased(\.items)),
        TourStep(id: "done", symbol: "checkmark", title: "Done", body: "Tick one.", goal: .increased(\.done)),
        TourStep(id: "undo", symbol: "arrow.uturn.backward", title: "Undo", body: "Delete, then Undo.", goal: .undone(\.deleted)),
        TourStep(id: "reorder", since: 2, symbol: "arrow.up.arrow.down", title: "Reorder", body: "Drag.", goal: .changed(\.order)),
        TourStep(id: "edit", since: 2, symbol: "pencil", title: "Edit", body: "Open one.", macBody: "Press ⌘E.", goal: .isTrue(\.editorOpen)),
    ]
    return .standard(appName: "Probe", version: version, steps: all.filter { $0.since <= version })
}

@Suite("Tour")
struct TourTests {
    @Test func firstRunGetsEverything() {
        let steps = catalog().steps(newerThan: 0)
        #expect(steps.map(\.id) == ["welcome", "add", "done", "undo", "reorder", "edit", "finish"])
    }

    @Test func whatsNewHasOnlyNewerSteps() {
        let steps = catalog().steps(newerThan: 1)
        #expect(steps.map(\.id) == ["whats-new", "reorder", "edit", "finish"])
        #expect(catalog().steps(newerThan: 2).isEmpty)
    }

    @Test func catalogIsValid() {
        #expect(catalog().problems().isEmpty)
    }

    @Test func catalogProblemsAreFound() {
        let broken = TourCatalog<Page>.standard(appName: "Probe", version: 3, steps: [
            TourStep(id: "add", symbol: "plus", title: "Add", body: "Add one."),
            TourStep(id: "add", since: 4, symbol: "plus", title: "", body: "Again."),
        ])
        let problems = broken.problems()
        #expect(problems.contains("duplicate step id add"))
        #expect(problems.contains("add: empty title"))
        #expect(problems.contains("add: since 4 is outside 1...3"))
        #expect(problems.contains("version 3 has no step with since: 3"))
    }

    @Test func goalsTickOff() {
        var tracker = TourTracker(baseline: Page())
        var page = Page()
        let add = TourGoal<Page>.increased(\.items)
        let notYet = tracker.isMet(add, now: page)
        #expect(!notYet)
        page.items = 4
        let met = tracker.isMet(add, now: page)
        #expect(met)
    }

    @Test func undoGoalNeedsTheRoundTrip() {
        var page = Page()
        var tracker = TourTracker(baseline: page)
        let goal = TourGoal<Page>.undone(\.deleted)
        page.deleted = 1
        let afterDelete = tracker.isMet(goal, now: page)
        page.deleted = 0
        let afterUndo = tracker.isMet(goal, now: page)
        #expect(!afterDelete)
        #expect(afterUndo)
    }

    @Test func reorderNeedsADifferentOrder() {
        var page = Page()
        var tracker = TourTracker(baseline: page)
        let goal = TourGoal<Page>.changed(\.order)
        let same = tracker.isMet(goal, now: page)
        page.order = ["b", "a", "c"]
        let moved = tracker.isMet(goal, now: page)
        #expect(!same)
        #expect(moved)
    }

    @Test func allGoalNeedsEveryPart() {
        var page = Page()
        var tracker = TourTracker(baseline: page)
        let goal = TourGoal<Page>.all([.increased(\.items), .increased(\.done)])
        page.items = 4
        let half = tracker.isMet(goal, now: page)
        page.done = 1
        let full = tracker.isMet(goal, now: page)
        #expect(!half)
        #expect(full)
    }

    @Test func progressWalksThroughTheSteps() {
        var page = Page()
        var progress = TourProgress(steps: catalog().allSteps, start: page)
        #expect(progress.step?.id == "welcome")
        #expect(progress.primaryTitle == "Let's Go")
        let moved = progress.next(at: page)
        #expect(moved)
        #expect(progress.step?.id == "add")
        #expect(progress.primaryTitle == "Skip")
        #expect(!progress.primaryIsProminent)
        page.items = 4
        let ticked = progress.observe(page)
        #expect(ticked)
        #expect(progress.primaryTitle == "Next")
        let again = progress.observe(page)
        #expect(!again)
        progress.back(at: page)
        #expect(progress.step?.id == "welcome")
    }

    @Test func progressCanStartAtAStep() {
        let progress = TourProgress(steps: catalog().allSteps, start: Page(), startAt: "undo")
        #expect(progress.step?.id == "undo")
        let unknown = TourProgress(steps: catalog().allSteps, start: Page(), startAt: "nope")
        #expect(unknown.index == 0)
    }

    @Test func lastStepFinishes() {
        var progress = TourProgress(steps: catalog().allSteps, start: Page(), startAt: "finish")
        #expect(progress.isLast)
        #expect(progress.primaryTitle == "Done")
        let moved = progress.next(at: Page())
        #expect(!moved)
    }

    @Test func scheduleOffersFullTourThenWhatsNewThenNothing() throws {
        let suite = "tour-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schedule = TourSchedule(defaults: defaults)
        #expect(schedule.stepsToOffer(catalog(version: 1)).count == 5)
        schedule.markSeen(catalog(version: 1))
        #expect(schedule.stepsToOffer(catalog(version: 1)).isEmpty)
        #expect(schedule.stepsToOffer(catalog(version: 2)).map(\.id) == ["whats-new", "reorder", "edit", "finish"])
        schedule.markSeen(catalog(version: 2))
        #expect(schedule.stepsToOffer(catalog(version: 2)).isEmpty)
    }

    @Test func macTextFallsBackToTouchText() {
        let step = catalog().steps[0]
        #expect(step.macBody == step.body)
        let edit = catalog().steps[4]
        #expect(edit.macBody == "Press ⌘E.")
    }
}
