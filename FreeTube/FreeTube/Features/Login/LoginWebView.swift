import SwiftUI
import WebKit
import OSLog

@available(iOS 17.0, *)
struct LoginWebView: UIViewRepresentable {
    @ObservedObject var coordinator: LoginCoordinator

    private static let log = AppLog(subsystem: "com.leshko.freetube", category: "LoginWebView")

    func makeCoordinator() -> Delegate { Delegate(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // **Ephemeral data store on purpose.** Reusing the shared `.default()` store made every
        // sign-in attempt instantly "succeed" by capturing stale cookies left over in WKWebView
        // from a previous (often half-completed) session — those cookies passed the name-set
        // check in `CookieStore.makeHeader` but were no longer valid, so YouTubeKit's
        // `AccountInfosResponse` came back `isDisconnected=true`. A nonPersistent store starts
        // cookie-empty, which forces Google to show the actual sign-in form and guarantees
        // every captured cookie comes from THIS session.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: LoginCoordinator.startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // No-op; the coordinator does the work.
    }

    final class Delegate: NSObject, WKNavigationDelegate {
        let parent: LoginWebView
        init(parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            LoginWebView.log.debug("[webview] didStart: \(webView.url?.absoluteString ?? "?", privacy: .public)")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            LoginWebView.log.debug("[webview] didCommit: \(webView.url?.absoluteString ?? "?", privacy: .public)")
            Task { @MainActor in
                parent.coordinator.handleNavigation(to: webView.url, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            LoginWebView.log.debug("[webview] didFinish: \(webView.url?.absoluteString ?? "?", privacy: .public)")
            Task { @MainActor in
                parent.coordinator.handleNavigation(to: webView.url, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            LoginWebView.log.error("[webview] didFail: \(error.localizedDescription, privacy: .public) url=\(webView.url?.absoluteString ?? "?", privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            LoginWebView.log.error("[webview] didFailProvisional: \(error.localizedDescription, privacy: .public) url=\(webView.url?.absoluteString ?? "?", privacy: .public)")
        }
    }
}
