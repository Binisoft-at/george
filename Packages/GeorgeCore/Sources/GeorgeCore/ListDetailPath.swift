import Foundation

/// iPad at regular width (the app's `SplitTabStack`): a tab's navigation path shown in two columns.
/// The list screens stay in the list column, the first item opened sits next to them and whatever
/// was opened from that item stacks on top of it in the detail column. When the window gets narrow
/// again (multitasking, Slide Over), the parts become one path in the same order – nothing open is lost.
///
/// Generic over the path's element (the app's `Route`) and the item it can hold (`DetailItem`).
public enum ListDetailPath {
    /// Splits `path` at its first item (`item` returns the item an element holds, nil for a list).
    public static func split<Element, Item>(
        _ path: [Element],
        item: (Element) -> Item?
    ) -> (lists: [Element], item: Item?, onTop: [Element]) {
        guard let index = path.firstIndex(where: { item($0) != nil }) else { return (path, nil, []) }
        return (Array(path[..<index]), item(path[index]), Array(path[(index + 1)...]))
    }

    /// The parts as one path again: the lists, the item and what's on top of it.
    public static func join<Element, Item>(
        lists: [Element],
        item: Item?,
        onTop: [Element],
        wrap: (Item) -> Element
    ) -> [Element] {
        lists + (item.map { [wrap($0)] } ?? []) + onTop
    }

    /// Opening `item` from the detail column: on top of what shows, with Back – not again when it
    /// already shows (the item itself with nothing on top, or the topmost entry).
    public static func push<Element: Equatable, Item: Equatable>(
        _ item: Item,
        shown: Item?,
        onTop: [Element],
        wrap: (Item) -> Element
    ) -> [Element] {
        let element = wrap(item)
        if onTop.last == element { return onTop }
        if onTop.isEmpty && shown == item { return onTop }
        return onTop + [element]
    }

    /// Whether something is opened on top of `item` (Back returns to it): it is the shown item with
    /// entries on top, or an entry below the topmost one. A covered page isn't left yet.
    public static func isCovered<Element: Equatable, Item: Equatable>(
        _ item: Item,
        shown: Item?,
        onTop: [Element],
        wrap: (Item) -> Element
    ) -> Bool {
        if shown == item && !onTop.isEmpty { return true }
        guard let index = onTop.firstIndex(of: wrap(item)) else { return false }
        return index < onTop.count - 1
    }

    /// What stays on top once `item` is closed (deleted): nothing when it was the shown item –
    /// what was opened from it goes with it – else the entries without it.
    public static func close<Element: Equatable, Item: Equatable>(
        _ item: Item,
        shown: Item?,
        onTop: [Element],
        wrap: (Item) -> Element
    ) -> [Element] {
        if shown == item { return [] }
        let element = wrap(item)
        return onTop.filter { $0 != element }
    }
}
