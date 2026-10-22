import AppKit
import WebKit

/// Serves the page, three.js and the characters from the app bundle as pet://app/...
/// (file:// URLs block ES modules and fetch). pet://app/user-characters/<name>/... reads
/// ~/.promptpaws/characters/<name>/..., so new characters work without a rebuild.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private let appRoot: URL
    private let userRoot: URL

    init(appRoot: URL, userRoot: URL) {
        self.appRoot = appRoot.standardizedFileURL
        self.userRoot = userRoot.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path
        let (base, rel): (URL, String) = path.hasPrefix("/user-characters/")
            ? (userRoot, String(path.dropFirst("/user-characters/".count)))
            : (appRoot, String(path.dropFirst()))
        let file = base.appendingPathComponent(rel).standardizedFileURL
        let inside = file.path.hasPrefix(base.path + "/")
        guard inside, let data = try? Data(contentsOf: file) else {
            Log.write("404 \(url.absoluteString)")
            respond(task, url: url, status: 404, type: "text/plain", data: Data())
            return
        }
        respond(task, url: url, status: 200, type: Self.mime(file.pathExtension), data: data)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, type: String, data: Data) {
        let headers = ["Content-Type": type, "Content-Length": "\(data.count)", "Cache-Control": "no-cache"]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "glb": return "model/gltf-binary"
        case "gltf": return "model/gltf+json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "ktx2": return "image/ktx2"
        default: return "application/octet-stream"
        }
    }
}

/// Forwards page messages without the web view holding the app strongly.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: PetView?
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        owner?.onMessage?(body)
    }
}

/// The web view that draws the pet, and the two-way link to its page.
final class PetView {
    let webView: WKWebView
    var onMessage: (([String: Any]) -> Void)?
    private let proxy = MessageProxy()
    private let scheme: SchemeHandler

    init(frame: NSRect) {
        scheme = SchemeHandler(appRoot: Bundle.main.resourceURL!,
                               userRoot: Log.dir.appendingPathComponent("characters", isDirectory: true))
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(scheme, forURLScheme: "pet")
        config.userContentController.add(proxy, name: "pet")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: frame, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        proxy.owner = self
    }

    /// `character` is a folder URL relative to the page, e.g. "../characters/robot/".
    func load(character: String) {
        var parts = URLComponents(string: "pet://app/web/index.html")!
        parts.queryItems = [URLQueryItem(name: "char", value: character)]
        webView.load(URLRequest(url: parts.url!))
    }

    /// Runs code and hands back its result (self-test).
    func query(_ code: String, _ done: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript(code) { result, _ in done(result) }
    }

    func js(_ code: String) {
        // ";0" so the result is always a plain number (some calls return objects or undefined).
        webView.evaluateJavaScript(code + ";0") { _, error in
            if let error { Log.write("js error for \(code): \(error.localizedDescription)") }
        }
    }
}
