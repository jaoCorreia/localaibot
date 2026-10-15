import SwiftUI
import WebKit
import AppKit

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
        // run first and stop it), and the Mac's pointer hides over the screen so
        // only the bot's cursor shows. `window.__localbotViewOnly` is flipped from Swift.
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
              s.textContent = `\(css)` + 'html.lb-view-only #screen, html.lb-view-only #screen * { cursor: none !important; }';
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
              if (s && /disconnect|failed|error|closed|wrong/i.test(s.textContent || '')) location.reload();
            }, 2500);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(reconnect)
        config.userContentController.addUserScript(WKUserScript(source: Self.keyboardBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "localbotClipboard")
        config.userContentController.add(context.coordinator, name: "localbotPaste")
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

    /// Mac shortcuts and clipboard while controlling a Linux device.
    /// - ⌘ + key goes to the device as Ctrl + key (copy, paste, select all, undo,
    ///   new tab…), except the ones macOS keeps (⌘Q, ⌘H, ⌘M, ⌘Tab).
    /// - The device's clipboard comes to the Mac when it changes (VNC cut text),
    ///   and ⌘V sends the Mac's clipboard to the device before pasting.
    /// noVNC keeps its RFB object private, so it's caught on its first event.
    private static let keyboardBridge = """
    (() => {
      const hook = document.createElement('script');
      hook.type = 'module';
      hook.textContent = `
        import RFB from './core/rfb.js';
        const original = RFB.prototype.dispatchEvent;
        RFB.prototype.dispatchEvent = function (event) {
          if (!window.__lbRFB) {
            window.__lbRFB = this;
            this.addEventListener('clipboard', (e) =>
              window.webkit.messageHandlers.localbotClipboard.postMessage(e.detail.text || ''));
          }
          return original.call(this, event);
        };`;
      document.documentElement.appendChild(hook);

      const CTRL = 0xffe3;
      const ctrlKey = (key, code) => {
        const rfb = window.__lbRFB;
        if (!rfb) return;
        const sym = key.length === 1 ? key.toLowerCase().charCodeAt(0) : null;
        if (sym === null) return;
        rfb.sendKey(CTRL, 'ControlLeft', true);
        rfb.sendKey(sym, code, true);
        rfb.sendKey(sym, code, false);
        rfb.sendKey(CTRL, 'ControlLeft', false);
      };
      window.__lbPaste = (text) => {
        const rfb = window.__lbRFB;
        if (!rfb) return;
        if (text) rfb.clipboardPasteFrom(text);
        // Let the device take the new clipboard before pasting it.
        setTimeout(() => ctrlKey('v', 'KeyV'), 60);
      };
      const macOnly = new Set(['q', 'h', 'm', 'tab', '`']);
      window.addEventListener('keydown', (e) => {
        if (window.__localbotViewOnly) return;
        if (e.key === 'Meta') { e.stopImmediatePropagation(); e.preventDefault(); return; }
        if (!e.metaKey || e.ctrlKey || macOnly.has(e.key.toLowerCase())) return;
        e.stopImmediatePropagation();
        e.preventDefault();
        if (e.key.toLowerCase() === 'v') window.webkit.messageHandlers.localbotPaste.postMessage('');
        else ctrlKey(e.key, e.code);
      }, { capture: true });
      window.addEventListener('keyup', (e) => {
        if (window.__localbotViewOnly) return;
        if (e.key === 'Meta' || e.metaKey) { e.stopImmediatePropagation(); e.preventDefault(); }
      }, { capture: true });
    })();
    """

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        var password: String?
        var loaded: URL?
        var controlling: Bool?

        /// The device copied something: put it on the Mac's clipboard. ⌘V: hand
        /// the Mac's clipboard to the device and paste.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "localbotClipboard":
                guard let text = message.body as? String, !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case "localbotPaste":
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                let json = (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
                message.webView?.evaluateJavaScript("window.__lbPaste(\(json)[0])")
            default:
                break
            }
        }

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

        /// A remote device answers with an HTTP error while its screen is still
        /// booting; that page would sit there dark and never reconnect. Retry instead.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard navigationResponse.isForMainFrame,
                  let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400,
                  let loaded else { return decisionHandler(.allow) }
            decisionHandler(.cancel)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak webView] in
                webView?.load(URLRequest(url: loaded))
            }
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
