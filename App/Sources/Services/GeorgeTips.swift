import SwiftUI
import BinisoftKit
import TipKit

/// Contextual hints (TipKit, set up by BinisoftKit `BinisoftTips`). Each shows once until
/// dismissed or acted on; Settings → Show Hints Again brings them back.
enum GeorgeTips {
    struct CreateTip: Tip {
        var title: Text { Text("Create anything here") }
        var message: Text? { Text("Start or plan a workout, make a template or a program, log a past session or an activity like tennis, or import a plan.") }
        var image: Image? { Image(systemName: "plus.circle.fill") }
    }

    struct SwipeTip: Tip {
        var title: Text { Text("Swipe for quick actions") }
        var message: Text? { Text("Swipe right on a workout to start or pin it, left to repeat, skip or delete. Long-press for everything else.") }
        var image: Image? { Image(systemName: "hand.draw") }
    }

    /// Live mode, first workout. Gone after the first set is done (`firstSetDone()`).
    struct LiveSetTip: Tip {
        var title: Text { Text("How a set works") }
        var message: Text? {
            if CoachPrefs.startButton {
                return Text("Tap Start when you begin a set and Done (or the circle) when you finish – the rest runs by itself. Tap a number to type it. Swiping only looks: the bar at the bottom always shows what's due.")
            }
            return Text("Tap the circle when you finish a set – the rest runs by itself. Tap a number to type it. Swiping only looks: the bar at the bottom always shows what's due.")
        }
        var image: Image? { Image(systemName: "checkmark.circle") }
    }

    /// The coach bar's Start button (shown only with Settings → Coach → Start button on).
    struct CoachStartTip: Tip {
        var title: Text { Text("Start, then Done") }
        var message: Text? { Text("Tap Start as you begin the set. George measures your real rest and shows whether you're ahead or behind the plan.") }
        var image: Image? { Image(systemName: "play.circle") }
    }

    /// "Can't finish? Lower the weight" in live mode.
    struct LowerWeightTip: Tip {
        var title: Text { Text("Can't finish the set?") }
        var message: Text? { Text("Lower the weight: the reps you managed count, and a lighter set follows right away – for this set or all that are left.") }
        var image: Image? { Image(systemName: "arrow.down.circle") }
    }

    /// Swap in live mode.
    struct SwapTip: Tip {
        var title: Text { Text("Machine taken?") }
        var message: Text? { Text("Swap the exercise: the sets you've done stay, the rest move to the new one.") }
        var image: Image? { Image(systemName: "arrow.triangle.swap") }
    }

    struct EditorTip: Tip {
        var title: Text { Text("Edit right in the list") }
        var message: Text? { Text("Tap an exercise to change it – “All sets” changes every open set at once. Tap a set chip to edit it, swipe for Swap and Delete, and use Reorder in ⋯ to move exercises.") }
        var image: Image? { Image(systemName: "hand.tap") }
    }

    /// Call when a set is completed in live mode: the "how a set works" tip has done its job.
    @MainActor
    static func firstSetDone() {
        LiveSetTip().invalidate(reason: .actionPerformed)
    }
}
