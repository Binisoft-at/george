import SwiftUI
import GeorgeCore

/// Settings → Thalia: George writes finished workouts for Thalia (Binisoft's planner) on this device.
struct ThaliaSettingsSection: View {
    @Environment(ThaliaSync.self) private var thalia

    var body: some View {
        @Bindable var thalia = thalia
        Section {
            Toggle(isOn: $thalia.isEnabled) {
                Label("Send to Thalia", systemImage: "arrow.left.arrow.right")
            }
            LabeledContent("Last written", value: lastWritten)
        } header: {
            Text("Thalia")
        } footer: {
            Text(footer)
        }
    }

    private var lastWritten: String {
        guard let date = thalia.lastWritten else { return "Not yet" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var footer: String {
        var text = "Thalia picks up your workouts as soon as Thalia is opened on this device. George only shares which workouts you finished – never numbers from Apple Health."
        if !thalia.isAvailable { text += " Not active here: George sends workouts to Thalia only while it syncs with iCloud." }
        return text
    }
}
