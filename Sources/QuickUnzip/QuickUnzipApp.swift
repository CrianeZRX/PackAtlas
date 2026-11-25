import SwiftUI
import AppKit
import ArchiveCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openFiles: (([URL]) -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        Self.openFiles?(urls)
    }
    @objc func extractSmart(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receiveService(pasteboard, layout: .smart)
    }
    @objc func extractFolder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receiveService(pasteboard, layout: .folder)
    }
    private func receiveService(_ pasteboard: NSPasteboard, layout: ExtractionLayout) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { Self.store?.add(urls, layoutOverride: layout); Self.store?.startQueue(); NSApp.activate(ignoringOtherApps: true) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = Self.store, store.pendingCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "解压任务尚未完成"
        alert.informativeText = "关闭窗口会继续后台解压。现在退出将取消剩余任务并清理临时文件。"
        alert.addButton(withTitle: "继续解压")
        alert.addButton(withTitle: "取消任务并退出")
        if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        for job in store.jobs where !job.state.isFinished { store.cancel(job.id) }
        // Wait for cooperative cancellation and staging cleanup before exiting.
        Task { @MainActor in
            while store.running { try? await Task.sleep(nanoseconds: 50_000_000) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    @MainActor static weak var store: AppStore?
}

@main
struct QuickUnzipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()
    init() {
        let model = AppStore()
        _store = StateObject(wrappedValue: model)
        AppDelegate.store = model
        AppDelegate.openFiles = { urls in model.add(urls) }
    }
    var body: some Scene {
        WindowGroup("轻解 · QuickUnzip") {
            ContentView(store: store)
                .onAppear {
                    AppDelegate.store = store
                    AppDelegate.openFiles = { urls in store.add(urls) }
                }
                .frame(minWidth: 900, minHeight: 650)
        }
        .defaultSize(width: 1050, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { Button("打开压缩文件…", action: store.chooseFiles).keyboardShortcut("o") }
            CommandGroup(replacing: .appSettings) { Button("设置…") { store.showsSettings = true }.keyboardShortcut(",") }
            CommandMenu("解压") {
                Button("开始队列", action: store.startQueue).keyboardShortcut(.return, modifiers: .command)
                Button("选择输出位置…", action: store.chooseDestination)
                Button("清除已结束任务", action: store.clearFinished)
            }
        }
    }
}
