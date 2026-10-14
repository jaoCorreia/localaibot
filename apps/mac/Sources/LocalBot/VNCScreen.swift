import SwiftUI
import WebKit

/// Shows a computer's screen over VNC using the noVNC page the computer serves.
/// `controlling == false` connects view-only, so watching never sends input.
struct VNCScreen: NSViewRepresentable {
    let url: String
    let password: String?
    let controlling: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // vnc_lite.html ships a status bar; hide it and let the canvas fill the view.
        let css = """
        #top_bar { display: none !important; }
        html, body { background: #0f0f0f !important; margin: 0; height: 100%; overflow: hidden; }
        #screen { height: 100% !important; background: transparent !important; }
        #screen > div { background: transparent !important; }
        """
        let script = WKUserScript(
            // Watching (view_only): keep the Mac's own pointer. noVNC otherwise swaps it for
            // the device's cursor image, which then doesn't follow the mouse.
            source: """
            const s = document.createElement('style');
            s.textContent = `\(css)` + (location.search.includes('view_only')
              ? '#screen, #screen * { cursor: default !important; }' : '');
            document.documentElement.appendChild(s);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(script)
        // The device may still be booting (or was restarted): retry until noVNC connects.
        let reconnect = WKUserScript(
            source: """
            setInterval(() => {
              const s = document.getElementById('status');
              if (s && /disconnect|failed|error/i.test(s.textContent || '')) location.reload();
            }, 2500);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(reconnect)
        let view = WKWebView(frame: .zero, configuration: config)
        view.uiDelegate = context.coordinator
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.password = password
        guard let target = pageURL, context.coordinator.loaded != target else { return }
        context.coordinator.loaded = target
        view.load(URLRequest(url: target))
    }

    /// Changing view-only means reconnecting; the URL is the source of truth.
    private var pageURL: URL? {
        guard var parts = URLComponents(string: url) else { return nil }
        var query = [URLQueryItem(name: "scale", value: "1"), URLQueryItem(name: "reconnect", value: "1")]
        if !controlling { query.append(URLQueryItem(name: "view_only", value: "1")) }
        parts.queryItems = query
        return parts.url
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        var password: String?
        var loaded: URL?

        /// noVNC asks for the password with window.prompt(); answer it here so the
        /// secret never goes in the URL.
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            completionHandler(password)
        }

        /// The device's web server may not be up yet; keep retrying quietly.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard let loaded else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak webView] in
                webView?.load(URLRequest(url: loaded))
            }
        }
    }
}
