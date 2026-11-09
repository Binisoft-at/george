import SwiftUI
import BinisoftKit
import TipKit

/// Contextual hints (TipKit, set up by BinisoftKit `BinisoftTips`). Each shows once until
/// dismissed or acted on; Settings → Show Hints Again brings them back.
enum GeorgeTips {
    struct CreateTip: Tip {
        var title: Text { Text("Create anything here") }
        var message: Text? { Text("Start or plan a workout, make a template or a program, log a past session or import a plan.") }
        var image: Image? { Image(systemName: "plus.circle.fill") }
    }

    struct SwipeTip: Tip {
        var title: Text { Text("Swipe for quick actions") }
        var message: Text? { Text("Swipe right on a workout to start or pin it, left to repeat, skip or delete. Long-press for everything else.") }
        var image: Image? { Image(systemName: "hand.draw") }
    }

    struct LiveSetTip: Tip {
        var title: Text { Text("Tick off sets") }
        var message: Text? { Text("Tap the circle to finish a set — the rest timer starts by itself. Tap a number to type it, drag it sideways to change it, long-press a set for more. Swipe for the next exercise.") }
        var image: Image? { Image(systemName: "checkmark.circle") }
    }

    struct EditorTip: Tip {
        var title: Text { Text("Edit right in the list") }
        var message: Text? { Text("Tap an exercise to change it, tap a set chip to edit it, swipe for Swap and Delete, long-press for supersets and more.") }
        var image: Image? { Image(systemName: "hand.tap") }
    }
}
