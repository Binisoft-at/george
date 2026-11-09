import SwiftUI
import BinisoftKit
import GeorgeCore

/// A number field that takes "62,5" as well as "62.5" and saves while you type – no Return key
/// needed (the decimal pad has none, so value-bound text fields lost what was typed).
struct NumberField: View {
    let placeholder: String
    @Binding var value: Double?
    var allowsDecimal = true
    var width: CGFloat? = 70

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            #if os(iOS)
            .keyboardType(allowsDecimal ? .decimalPad : .numberPad)
            #endif
            .focused($isFocused)
            .monospacedDigit()
            .frame(maxWidth: width)
            .onAppear { text = Self.text(for: value, allowsDecimal: allowsDecimal) }
            .onChange(of: text) { _, newText in
                let parsed = NumberParser.double(newText).map { allowsDecimal ? $0 : $0.rounded() }
                if parsed != value { value = parsed }
            }
            .onChange(of: value) { _, newValue in
                // Outside changes (another device, "same for the remaining sets") while not typing.
                guard !isFocused else { return }
                text = Self.text(for: newValue, allowsDecimal: allowsDecimal)
            }
    }

    static func text(for value: Double?, allowsDecimal: Bool) -> String {
        value.map { Format.number(allowsDecimal ? $0 : $0.rounded()) } ?? ""
    }
}
