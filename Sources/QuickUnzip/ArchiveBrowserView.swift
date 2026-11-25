import SwiftUI
import AppKit
import QuickLookUI
import ArchiveCore

struct BrowserEntry: Identifiable {
    var id: String { path }
    let path: String
    let size: Int64
    let directory: Bool
    var name: String { (path as NSString).lastPathComponent }
}

struct ArchiveBrowserView: View {
    let source: URL
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ArchivePreview?
    @State private var error: String?
    @State private var search = ""
    @State private var directory = ""
    @State private var selection = Set<String>()
    @State private var password = ""
    @State private var needsPassword = false
    @State private var itemLimit = 10_000
    @State private var busy = false
    @State private var token = CancellationToken()
    @State private var quickLook: URL?
    @State private var temporary: URL?
    @State private var encoding: FilenameEncoding = .automatic
    @State private var order = [KeyPathComparator(\BrowserEntry.path)]

    private var entries: [BrowserEntry] {
        guard let preview else { return [] }
        if !search.isEmpty {
            return preview.items.filter { $0.path.localizedCaseInsensitiveContains(search) }.map { BrowserEntry(path: $0.path, size: $0.size, directory: $0.isDirectory) }.sorted(using: order)
        }
        let prefix = directory.isEmpty ? "" : directory + "/"
        var rows: [String: BrowserEntry] = [:]
        for item in preview.items where item.path.hasPrefix(prefix) {
            let remainder = String(item.path.dropFirst(prefix.count))
            let parts = remainder.split(separator: "/")
            guard let first = parts.first else { continue }
            let path = prefix + first
            let isDir = parts.count > 1 || item.isDirectory
            if let current = rows[path] { rows[path] = BrowserEntry(path: path, size: current.size + (item.isDirectory ? 0 : item.size), directory: current.directory || isDir) }
            else { rows[path] = BrowserEntry(path: path, size: item.isDirectory ? 0 : item.size, directory: isDir) }
        }
        return rows.values.sorted(using: order)
    }
    private var selectedEntry: BrowserEntry? { selection.count == 1 ? entries.first { selection.contains($0.id) } : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "archivebox").font(.system(size: 26)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.lastPathComponent).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                    Text(preview?.format ?? ArchiveEngine.detectedFormat(source: source) ?? "读取压缩包").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField(preview?.isTruncated == true ? "搜索已加载的条目…" : "搜索整个压缩包…", text: $search).textFieldStyle(.roundedBorder)
                Picker("编码", selection: $encoding) { ForEach(FilenameEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 205)
                    .disabled(busy).onChange(of: encoding) { _ in reload() }
            }
            if needsPassword {
                HStack { Image(systemName: "lock"); SecureField("压缩包密码", text: $password).onSubmit(reload); Button("解锁目录", action: reload).disabled(password.isEmpty || busy) }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled).lineLimit(4) }
            if let comment = preview?.comment {
                DisclosureGroup("压缩包注释") { ScrollView { Text(comment).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 70) }
            }
            HStack(spacing: 12) {
                Button { directory = (directory as NSString).deletingLastPathComponent; selection = [] } label: { Image(systemName: "arrow.up") }.disabled(directory.isEmpty)
                Button("根目录") { directory = ""; search = ""; selection = [] }
                Button("打开文件夹") { if let item = selectedEntry, item.directory { directory = item.path; search = ""; selection = [] } }.disabled(selectedEntry?.directory != true)
                Text(directory.isEmpty ? "/" : directory).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }.buttonStyle(.borderless)
            Table(entries, selection: $selection, sortOrder: $order) {
                TableColumn("文件名", value: \.path) { item in
                    Label(search.isEmpty ? item.name : item.path, systemImage: item.directory ? "folder" : "doc")
                        .font(.system(size: 12)).onTapGesture(count: 2) { if item.directory { directory = item.path; search = ""; selection = [] } else { selection = [item.path]; showQuickLook(item) } }
                }
                TableColumn("大小", value: \.size) { item in Text(byteString(item.size)).font(.system(size: 11)).monospacedDigit() }.width(105)
                TableColumn("类型") { item in Text(item.directory ? "文件夹" : (item.name as NSString).pathExtension.uppercased()).font(.system(size: 10)).foregroundStyle(.secondary) }.width(70)
            }
            .contextMenu {
                Button("解压选中项", action: extractSelection).disabled(selection.isEmpty || busy)
                Button("预览") { if let item = selectedEntry { showQuickLook(item) } }.disabled(selectedEntry?.directory != false || busy)
                Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selection.sorted().joined(separator: "\n"), forType: .string) }.disabled(selection.isEmpty)
            }
            HStack {
                let count = preview?.items.filter { !$0.isDirectory }.count ?? 0
                Text("\(count) 个文件 · \(byteString(preview?.items.reduce(0) { $0 + $1.size } ?? 0))").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if let preview, preview.isTruncated {
                    Button("加载更多条目") {
                        itemLimit = preview.items.count + 10_000
                        reload()
                    }.disabled(busy)
                }
                Button("测试完整性") { store.test(source); dismiss() }.disabled(preview == nil || busy || store.running)
                Button("预览") { if let item = selectedEntry { showQuickLook(item) } }.disabled(selectedEntry?.directory != false || busy || store.running)
                Button("解压选中 \(selection.count) 项", action: extractSelection).disabled(selection.isEmpty || busy || store.running)
                Button("全部解压") { store.enqueueSelection(source, paths: [], password: effectivePassword); dismiss() }.buttonStyle(.borderedProminent).disabled(preview == nil || busy || store.running)
            }
        }.padding(25).frame(width: 860, height: 570).tint(accent)
            .onAppear { encoding = store.encoding; password = store.passwordFor(source) ?? ""; reload() }
            .onDisappear { token.cancel(); cleanup() }
            .sheet(item: $quickLook, onDismiss: cleanup) { url in
                VStack { HStack { Text(url.lastPathComponent).font(.headline); Spacer(); Button("关闭") { quickLook = nil } }; QuickLookPane(url: url) }.padding(20).frame(width: 760, height: 540)
            }
    }
    private var effectivePassword: String? { password.isEmpty ? store.passwordFor(source) : password }
    private func reload() {
        guard !busy else { return }
        busy = true; error = nil; token.cancel(); token = CancellationToken()
        let token = token, password = effectivePassword, encoding = encoding, limit = itemLimit
        Task {
            let result = await Task.detached(priority: .utility) { Result { try ArchiveEngine.preview(source: source, encoding: encoding, limit: limit, password: password, token: token) } }.value
            busy = false
            switch result {
            case .success(let value): preview = value; needsPassword = false; if let password { store.remember(password, source: source) }
            case .failure(let value):
                if case ArchiveFailure.passwordRequired = value { needsPassword = true }
                else if case ArchiveFailure.wrongPassword = value { needsPassword = true }
                if case ArchiveFailure.cancelled = value {} else { error = value.localizedDescription }
            }
        }
    }
    private func extractSelection() { store.enqueueSelection(source, paths: selection, password: effectivePassword); dismiss() }
    private func cleanup() { if let temporary { try? FileManager.default.removeItem(at: temporary); self.temporary = nil } }
    private func showQuickLook(_ item: BrowserEntry) {
        let supported = ["txt", "md", "csv", "json", "yaml", "yml", "log", "png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "mp3", "wav", "m4a", "mp4", "mov", "rtf"]
        guard !item.directory, supported.contains((item.name as NSString).pathExtension.lowercased()), item.size > 0, item.size <= 256 * 1024 * 1024 else { error = "预览需要已知文件大小，支持 256 MiB 以内的图片、文档和音视频。"; return }
        guard !busy else { return }
        busy = true; error = nil; cleanup()
        let password = effectivePassword, encoding = encoding, token = token
        Task {
            let result = await Task.detached(priority: .utility) { Result { () -> (URL, URL) in
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("QuickUnzip-Preview-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                do {
                    var options = ExtractionOptions(); options.selectedPaths = [item.path]
                    let result = try ArchiveEngine.extract(source: source, destinationParent: temp, password: password, encoding: encoding, token: token, options: options)
                    return (temp, result.destination.appendingPathComponent(item.path))
                } catch { try? FileManager.default.removeItem(at: temp); throw error }
            } }.value
            busy = false
            switch result { case .success(let pair): temporary = pair.0; quickLook = pair.1; case .failure(let value): error = value.localizedDescription }
        }
    }
}

private struct QuickLookPane: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { let view = QLPreviewView(frame: .zero, style: .normal)!; view.autostarts = false; view.previewItem = url as NSURL; return view }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}
