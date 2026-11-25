import AppKit
import ArchiveCore
import WebKit

private let browserAPI = """
window.qz = {
    call: (action, data) => window.webkit.messageHandlers.workbench.postMessage({action, data}),
    onOpen: listener => window.addEventListener('qzOpen', e => listener(e.detail)),
    onProgress: listener => window.addEventListener('qzProgress', e => listener(e.detail))
};
"""

final class ArchiveWebView: WKWebView {
    var openFiles: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        guard !files.isEmpty else { return false }
        openFiles?(files)
        return true
    }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

final class Workbench: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    var window: NSWindow!
    var browser: ArchiveWebView!
    var sources: [String: URL] = [:]
    var pending: [[String: Any]] = []
    var destination: URL?
    var operation: (String, CancellationToken)?
    var sampleDirectory: URL?
    var ready = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: browserAPI, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "workbench")
        browser = ArchiveWebView(frame: .zero, configuration: config)
        browser.navigationDelegate = self
        browser.uiDelegate = self
        browser.registerForDraggedTypes([.fileURL])
        browser.openFiles = { [weak self] urls in self?.enqueue(urls) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1190, height: 804), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 680, height: 550)
        window.title = "PackAtlas"
        window.contentView = browser
        window.center()
        installMenu()
        if let ui = Bundle.main.resourceURL?.appendingPathComponent("Workbench", isDirectory: true) {
            browser.loadFileURL(ui.appendingPathComponent("index.html"), allowingReadAccessTo: ui)
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        enqueue(CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) })
    }

    func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit PackAtlas", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApplication.shared.mainMenu = menu
    }

    func application(_ application: NSApplication, open urls: [URL]) { enqueue(urls) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let operation else { return .terminateNow }
        operation.1.cancel()
        acceptingTermination = true
        return .terminateLater
    }

    private var acceptingTermination = false

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.standardizedFileURL
        let entry = Bundle.main.resourceURL?.appendingPathComponent("Workbench/index.html").standardizedFileURL
        decisionHandler(url?.isFileURL == true && url == entry ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func enqueue(_ urls: [URL]) {
        let records = register(urls)
        if ready { emit("qzOpen", records) } else { pending += records }
    }

    func register(_ urls: [URL]) -> [[String: Any]] {
        urls.compactMap { raw in
            guard raw.isFileURL else { return nil }
            let source = ArchiveVolumes.firstVolume(for: raw).standardizedFileURL
            guard let info = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), info.isRegularFile == true else { return nil }
            let id = sources.first(where: { $0.value == source })?.key ?? UUID().uuidString
            sources[id] = source
            return ["id":id, "name":source.lastPathComponent, "size":info.fileSize ?? 0, "format":ArchiveEngine.detectedFormat(source: source) ?? ""]
        }
    }

    func emit(_ name: String, _ payload: Any) {
        browser?.callAsyncJavaScript("window.dispatchEvent(new CustomEvent(name, {detail: payload}));",
                                     arguments: ["name": name, "payload": payload], in: nil, in: .page, completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler reply: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let action = body["action"] as? String, let data = body["data"] as? [String: Any] else {
            reply(["error":"operationFailed"], nil); return
        }
        switch action {
        case "info": reply(["native":true,"platform":"macOS","description":ArchiveEngine.version + " + 7-Zip"], nil)
        case "pending": ready = true; reply(pending, nil); pending.removeAll()
        case "pick", "folder":
            let panel = NSOpenPanel()
            panel.canChooseFiles = action == "pick"
            panel.canChooseDirectories = action == "folder"
            panel.canCreateDirectories = action == "folder"
            panel.allowsMultipleSelection = action == "pick"
            panel.beginSheetModal(for: window) { response in
                if action == "pick" { reply(response == .OK ? self.register(panel.urls) : [], nil); return }
                if response == .OK { self.destination = panel.url }
                reply(response == .OK ? panel.url?.path : nil, nil)
            }
        case "sample":
            do {
                let manager = FileManager.default
                let dir = try self.sampleDirectory ?? manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                    appropriateFor: manager.homeDirectoryForCurrentUser, create: true)
                self.sampleDirectory = dir
                let sample = dir.appendingPathComponent("PackAtlas Sample.zip")
                if !manager.fileExists(atPath: sample.path), let original = Bundle.main.resourceURL?.appendingPathComponent("Workbench/sample.zip") {
                    try manager.copyItem(at: original, to: sample)
                }
                reply(register([sample]), nil)
            } catch { reply(["error":"operationFailed","detail":error.localizedDescription], nil) }
        case "reveal":
            guard let path = data["path"] as? String, FileManager.default.fileExists(atPath: path) else {
                reply(["error":"notFound"], nil); return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            reply(true, nil)
        case "cancel":
            if let op = operation, data["job"] as? String == op.0 { op.1.cancel() }
            reply(true, nil)
        case "list", "test", "extract": process(action, data, reply: reply)
        default: reply(["error":"operationFailed"], nil)
        }
    }

    func process(_ action: String, _ data: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard operation == nil, let id = data["id"] as? String, let source = sources[id] else {
            reply(["error":"notFound"], nil); return
        }
        let token = CancellationToken()
        operation = (id, token)
        let folder = data["destination"] as? String == destination?.path ? (destination ?? source.deletingLastPathComponent()) : source.deletingLastPathComponent()
        let password = data["password"] as? String
        let encodings: [String: FilenameEncoding] = ["utf8":.utf8,"gb18030":.gb18030,"big5":.big5,"japanese":.japanese,"korean":.korean]
        let encoding = encodings[data["encoding"] as? String ?? ""] ?? .automatic
        let limit = min(200_000, max(1, data["limit"] as? Int ?? 10_000))
        var opts = ExtractionOptions()
        let layouts: [String: ExtractionLayout] = ["folder":.folder,"here":.here,"smart":.smart]
        opts.layout = layouts[data["layout"] as? String ?? ""] ?? .smart
        opts.performance = data["performance"] as? String == "fast" ? .foreground : data["performance"] as? String == "background" ? .background : .balanced
        opts.conflictPolicy = data["conflict"] as? String == "skip" ? .skip : .rename
        opts.ignoreMacMetadata = data["ignoreMac"] as? Bool ?? false
        opts.selectedPaths = Set(data["selection"] as? [String] ?? [])
        let options = opts
        DispatchQueue.global(qos: .utility).async {
            let report: (ExtractionProgress) -> Void = { [weak self] progress in
                guard progress.fraction.isFinite else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.emit("qzProgress", ["id":id,"percent":Int(max(0, min(1, progress.fraction))*100)])
                }
            }
            let result: [String: Any]
            do {
                switch action {
                case "list":
                    let list = try ArchiveEngine.preview(source: source, encoding: encoding, limit: limit, password: password, token: token)
                    result = ["format":list.format, "truncated":list.isTruncated && limit < 200_000, "items":list.items.map { ["path":$0.path,"size":$0.size,"directory":$0.isDirectory] }]
                case "test":
                    let check = try ArchiveEngine.testIntegrity(source: source, password: password, encoding: encoding, token: token, progress: report)
                    result = ["format":check.format, "bytes":check.bytesRead]
                default:
                    let output = try ArchiveEngine.extract(source: source, destinationParent: folder, password: password, encoding: encoding, token: token, options: options, progress: report)
                    result = ["format":output.format, "bytes":output.bytesWritten, "output":output.outputs.first?.path ?? output.destination.path]
                }
            } catch ArchiveFailure.passwordRequired { result = ["error":"password"] }
            catch ArchiveFailure.wrongPassword { result = ["error":"wrongPassword"] }
            catch ArchiveFailure.cancelled { result = ["error":"cancelled"] }
            catch { result = ["error":"operationFailed","detail":error.localizedDescription] }
            DispatchQueue.main.async {
                self.operation = nil
                reply(result, nil)
                if self.acceptingTermination { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
            }
        }
    }
}

let app = NSApplication.shared
let workbench = Workbench()
app.setActivationPolicy(.regular)
app.delegate = workbench
app.run()
