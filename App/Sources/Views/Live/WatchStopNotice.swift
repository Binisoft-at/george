import SwiftUI
import GeorgeCore

/// "Apple Watch stopped recording – George saves the rest from iPhone": the watch's recording ended
/// while the workout goes on (ended there, a late Discard, or watchOS). Live mode covers toasts, so
/// it shows here, above the coach bar, until closed or the watch records again.
struct WatchStopNotice: View {
    @Environment(LiveWorkoutController.self) private var live

    var body: some View {
        if let text = live.watchStopNotice {
            HStack(spacing: 10) {
                Image(systemName: "applewatch.slash")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                closeButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var closeButton: some View {
        Button {
            withAnimation(.snappy) { live.dismissWatchStopNotice() }
        } label: {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
