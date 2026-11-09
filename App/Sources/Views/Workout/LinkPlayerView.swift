import SwiftUI
import BinisoftKit
import GeorgeCore
#if os(iOS)
import SafariServices
#elseif os(macOS)
import WebKit
#endif

/// Plays a tutorial link in-app (YouTube, video, GIF or any web page).
struct LinkPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        #if os(iOS)
        SafariView(url: url)
            .ignoresSafeArea()
        #else
        VStack(spacing: 0) {
            HStack {
                Text(url.host ?? url.absoluteString)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Open in Browser") { openURL(url) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            MacWebView(url: url)
        }
        .frame(minWidth: 720, minHeight: 520)
        #endif
    }
}

#if os(iOS)
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#elseif os(macOS)
private struct MacWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
