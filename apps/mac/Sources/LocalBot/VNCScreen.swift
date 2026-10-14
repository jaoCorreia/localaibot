import SwiftUI
import WebKit

/// Shows a computer's screen over VNC using the noVNC page the computer serves.
/// `controlling == false` is view-only: the page swallows input before noVNC
/// sees it. Switching doesn't reload the page, so the session stays connected
/// (reconnecting to a cloud device shows black for a while).
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
        // Watching: input never reaches noVNC (capture-phase listeners on the window
        // run first and stop it), and the Mac keeps its own pointer instead of the
        // device's cursor image. `window.__localbotViewOnly` is flipped from Swift.
        let script = WKUserScript(
            source: """
            window.__localbotViewOnly = \(!controlling);
            const block = (e) => { if (window.__localbotViewOnly) { e.stopImmediatePropagation(); e.preventDefault(); } };
            for (const t of ['mousedown','mouseup','mousemove','click','dblclick','contextmenu','wheel',
                             'keydown','keyup','keypress','touchstart','touchmove','touchend',
                             'pointerdown','pointerup','pointermove'])
              window.addEventListener(t, block, { capture: true, passive: false });
            document.addEventListener('DOMContentLoaded', () => {
              const s = document.createElement('style');
              s.textContent = `\(css)` + 'html.lb-view-only #screen, html.lb-view-only #screen * { cursor: default !important; }';
              document.documentElement.appendChild(s);
              document.documentElement.classList.toggle('lb-view-only', window.__localbotViewOnly);
            });
            """,
            injectionTime: .atDocumentStart,
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
        if context.coordinator.controlling != controlling {
            context.coordinator.controlling = controlling
            let viewOnly = controlling ? "false" : "true"
            view.evaluateJavaScript(
                "window.__localbotViewOnly = \(viewOnly); document.documentElement.classList.toggle('lb-view-only', \(viewOnly));")
            // Typing goes to the device only while controlling.
            if controlling { view.window?.makeFirstResponder(view) }
        }
        guard let target = pageURL, context.coordinator.loaded != target else { return }
        context.coordinator.loaded = target
        view.load(URLRequest(url: target))
    }

    /// The page to load. View-only is switched in place, so it isn't part of it.
    private var pageURL: URL? {
        guard var parts = URLComponents(string: url) else { return nil }
        let query = [URLQueryItem(name: "scale", value: "1"), URLQueryItem(name: "reconnect", value: "1")]
        // Keep the device's own query (a remote device's token opens its screen).
        let own = (parts.queryItems ?? []).filter { !["scale", "reconnect", "view_only"].contains($0.name) }
        parts.queryItems = own + query
        return parts.url
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        var password: String?
        var loaded: URL?
        var controlling: Bool?

        /// noVNC asks for the password with window.prompt(); answer it here so the
        /// secret never goes in the URL.
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            completionHandler(password)
        }

        /// The page reloads itself to reconnect; reapply the current mode each time.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let viewOnly = controlling == true ? "false" : "true"
            webView.evaluateJavaScript(
                "window.__localbotViewOnly = \(viewOnly); document.documentElement.classList.toggle('lb-view-only', \(viewOnly));")
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
