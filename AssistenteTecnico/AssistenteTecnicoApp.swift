import SwiftUI
import WebKit
import UniformTypeIdentifiers

@main
struct AssistenteTecnicoApp: App {
    var body: some Scene {
        WindowGroup {
            WebAppView()
                .ignoresSafeArea()
                .background(Color(UIColor.sfondoApp))
        }
    }
}

extension UIColor {
    /// Stesso sfondo dell'app web, chiaro o scuro
    static let sfondoApp = UIColor { tratti in
        tratti.userInterfaceStyle == .dark
            ? UIColor(red: 0.078, green: 0.102, blue: 0.122, alpha: 1)
            : UIColor(red: 0.933, green: 0.941, blue: 0.925, alpha: 1)
    }
}

/// Serve i file dell'app da assistente://app/ — un'origine stabile, così IndexedDB
/// conserva l'archivio tra un avvio e l'altro (come in Carlucci'sHome).
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "assistente"
    let root = Bundle.main.resourceURL!.appendingPathComponent("Web")

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst()))
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct WebAppView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: BundleSchemeHandler.scheme)
        cfg.allowsInlineMediaPlayback = true
        let ucc = cfg.userContentController
        ucc.add(context.coordinator, name: "native")
        ucc.addUserScript(WKUserScript(source: "window.__NATIVE_IOS__ = true;",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .sfondoApp
        wv.scrollView.backgroundColor = .sfondoApp
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { wv.isInspectable = true }   // ispezionabile da Safari su Mac, utile per i problemi
        context.coordinator.webView = wv
        wv.load(URLRequest(url: URL(string: "\(BundleSchemeHandler.scheme)://app/index.html")!))
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, URLSessionDataDelegate {
        weak var webView: WKWebView?

        // ---------- richieste di rete per l'app web (Gemini, OpenRouter) ----------
        // Fatte qui e non nella pagina: niente blocchi CORS, avanzamento dell'invio,
        // e iOS lascia finire la richiesta per qualche secondo anche se esci dall'app.
        private lazy var session: URLSession = {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = 600
            c.timeoutIntervalForResource = 900
            c.waitsForConnectivity = false
            return URLSession(configuration: c, delegate: self, delegateQueue: OperationQueue.main)
        }()
        private var tasks: [String: URLSessionDataTask] = [:]
        private var idPerTask: [Int: String] = [:]
        private var dati: [Int: Data] = [:]
        private var scaduti: Set<String> = []
        private var sfondo: [String: UIBackgroundTaskIdentifier] = [:]

        private func avviaRichiesta(_ b: [String: Any]) {
            guard let id = b["id"] as? String, let s = b["url"] as? String, let url = URL(string: s) else { return }
            var req = URLRequest(url: url)
            req.httpMethod = (b["method"] as? String) ?? "GET"
            if let h = b["headers"] as? [String: Any] {
                for (k, v) in h { req.setValue("\(v)", forHTTPHeaderField: k) }
            }
            if let body = b["body"] as? String { req.httpBody = body.data(using: .utf8) }
            let ms = (b["timeout"] as? NSNumber)?.doubleValue ?? 90000
            req.timeoutInterval = max(30, ms / 1000)

            let task = session.dataTask(with: req)
            tasks[id] = task
            idPerTask[task.taskIdentifier] = id
            dati[task.taskIdentifier] = Data()
            sfondo[id] = UIApplication.shared.beginBackgroundTask(withName: "analisi") { [weak self] in
                self?.fineSfondo(id)
            }
            // limite di tempo totale (quello di URLRequest conta solo i silenzi)
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { [weak self] in
                guard let self, let t = self.tasks[id] else { return }
                self.scaduti.insert(id)
                t.cancel()
            }
            task.resume()
        }

        private func fineSfondo(_ id: String) {
            if let t = sfondo.removeValue(forKey: id), t != .invalid { UIApplication.shared.endBackgroundTask(t) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard let id = idPerTask[task.taskIdentifier], totalBytesExpectedToSend > 0 else { return }
            let quota = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            chiamaJS("window.__nativeHTTPProgress", [id, quota])
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            dati[dataTask.taskIdentifier, default: Data()].append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let id = idPerTask.removeValue(forKey: task.taskIdentifier) else { return }
            let corpo = dati.removeValue(forKey: task.taskIdentifier) ?? Data()
            tasks.removeValue(forKey: id)
            let scaduto = scaduti.remove(id) != nil
            var esito: [String: Any] = [:]
            if let error {
                let codice = (error as? URLError)?.code
                if scaduto || codice == .timedOut { esito["error"] = "tempo" }
                else if codice == .cancelled { esito["error"] = "annullato" }
                else { esito["error"] = "rete" }
            } else {
                esito["status"] = (task.response as? HTTPURLResponse)?.statusCode ?? 0
                esito["text"] = String(data: corpo, encoding: .utf8) ?? ""
            }
            chiamaJS("window.__nativeHTTPDone", [id, esito])
            fineSfondo(id)
        }

        private func chiamaJS(_ funzione: String, _ argomenti: [Any]) {
            guard let d = try? JSONSerialization.data(withJSONObject: argomenti),
                  let s = String(data: d, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("\(funzione) && \(funzione).apply(null, \(s))")
        }

        // ---------- messaggi dall'app web ----------
        func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
            guard let body = msg.body as? [String: Any], let action = body["action"] as? String else { return }
            switch action {
            case "http":
                avviaRichiesta(body)
            case "httpCancel":
                if let id = body["id"] as? String { tasks[id]?.cancel() }
            case "saveFile":
                guard let name = body["name"] as? String, let b64 = body["data"] as? String,
                      let data = Data(base64Encoded: b64) else { return }
                let safe = name.replacingOccurrences(of: "/", with: "-")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
                try? data.write(to: url, options: .atomic)
                condividi([url])
            default:
                break
            }
        }

        private func condividi(_ items: [Any]) {
            guard let wv = webView, let root = wv.window?.rootViewController else { return }
            var top = root
            while let p = top.presentedViewController { top = p }
            let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
            vc.popoverPresentationController?.sourceView = wv
            vc.popoverPresentationController?.sourceRect = CGRect(x: wv.bounds.midX, y: wv.bounds.maxY - 80, width: 1, height: 1)
            top.present(vc, animated: true)
        }

        // Link esterni (http/https/mailto/tel) → Safari o app di sistema
        func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, let s = url.scheme?.lowercased(),
               s != BundleSchemeHandler.scheme, s != "about", s != "blob", s != "data" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // window.open: niente popup, eventuali link esterni vanno a Safari
        func webView(_ wv: WKWebView, createWebViewWith c: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url)
            }
            return nil
        }

        // Se iOS chiude il motore della pagina per memoria (succede con video pesanti), la ricarica
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }
    }
}
