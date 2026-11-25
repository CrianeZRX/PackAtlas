import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore

enum JobState: Equatable {
    case queued, running, paused, needsPassword, needsConflict, done, failed, cancelled
    var title: String {
        switch self {
        case .queued: return "等待解压"
        case .running: return "正在解压"
        case .paused: return "已暂停"
        case .needsConflict: return "等待处理同名文件"
        case .needsPassword: return "需要密码"
        case .done: return "解压完成"
        case .failed: return "解压失败"
        case .cancelled: return "已取消"
        }
    }
    var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
}

struct ExtractionJob: Identifiable {
    let id = UUID()
    let source: URL
    let compressedSize: Int64
    var state: JobState = .queued
    var kind: JobKind = .extract
    var options = ExtractionOptions()
    var conflicts: [String] = []
    var integrity: IntegrityResult?
    var format = "自动识别"
    var progress: Double = 0
    var currentFile = ""
    var bytesWritten: Int64 = 0
    var files = 0
    var error: String?
    var result: ExtractionResult?
    var startedAt: Date?
    var bytesPerSecond: Double {
        guard let startedAt else { return 0 }
        return Double(bytesWritten) / max(0.1, Date().timeIntervalSince(startedAt))
    }
}

enum JobKind: String { case extract, test }

enum QueueFilter: String, CaseIterable { case all = "全部任务", active = "正在处理", completed = "已完成" }

@MainActor
final class AppStore: ObservableObject {
    @Published var jobs: [ExtractionJob] = []
    @Published var filter: QueueFilter = .all
    @Published var showsSettings = false
    @Published var previewSource: URL?
    @Published var autoExtract = UserDefaults.standard.object(forKey: "autoExtract") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoExtract, forKey: "autoExtract"); if autoExtract { schedule() } }
    }
    @Published var revealWhenDone = UserDefaults.standard.bool(forKey: "revealWhenDone") {
        didSet { UserDefaults.standard.set(revealWhenDone, forKey: "revealWhenDone") }
    }
    @Published var destination: URL? = UserDefaults.standard.string(forKey: "destination").map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(destination?.path, forKey: "destination") }
    }
    @Published var encoding = FilenameEncoding(rawValue: UserDefaults.standard.string(forKey: "encoding") ?? "") ?? .automatic {
        didSet { UserDefaults.standard.set(encoding.rawValue, forKey: "encoding") }
    }
    @Published var layout = ExtractionLayout(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "") ?? .smart { didSet { UserDefaults.standard.set(layout.rawValue, forKey: "layout") } }
    @Published var conflictPolicy = ConflictPolicy(rawValue: UserDefaults.standard.string(forKey: "conflictPolicy") ?? "") ?? .rename { didSet { UserDefaults.standard.set(conflictPolicy.rawValue, forKey: "conflictPolicy") } }
    @Published var normalization = UnicodeNormalization(rawValue: UserDefaults.standard.string(forKey: "normalization") ?? "") ?? .unchanged { didSet { UserDefaults.standard.set(normalization.rawValue, forKey: "normalization") } }
    @Published var performance = PerformanceMode(rawValue: UserDefaults.standard.string(forKey: "performance") ?? "") ?? .balanced { didSet { UserDefaults.standard.set(performance.rawValue, forKey: "performance") } }
    @Published var ignoreMacMetadata = UserDefaults.standard.bool(forKey: "ignoreMacMetadata") { didSet { UserDefaults.standard.set(ignoreMacMetadata, forKey: "ignoreMacMetadata") } }
    @Published var rememberPasswords = true { didSet { if !rememberPasswords { sessionPasswords.removeAll() } } }
    @Published var queueStarted = false
    @Published var decoderDescription = ArchiveEngine.decoderDescription
    @Published var decoderNote: String?
    func importDecoder() {
        let panel = NSOpenPanel(); panel.title = "选择官方 macOS 下载包中的 7zz"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ArchiveEngine.importDecoder(from: url); decoderDescription = ArchiveEngine.decoderDescription; decoderNote = "已导入，新任务将自动使用新引擎。" }
        catch { decoderNote = error.localizedDescription }
    }
    private var sessionPasswords: [URL: String] = [:]
    var currentOptions: ExtractionOptions {
        var o = ExtractionOptions(); o.layout = layout; o.conflictPolicy = conflictPolicy; o.normalization = normalization; o.performance = performance; o.ignoreMacMetadata = ignoreMacMetadata
        return o
    }
    var conflictJob: ExtractionJob? { jobs.first { $0.state == .needsConflict } }
    func passwordFor(_ source: URL) -> String? { sessionPasswords[source] }
    func remember(_ password: String, source: URL) { if rememberPasswords { sessionPasswords[source] = password } }
    func browse(_ source: URL) { previewSource = source }
    func enqueueSelection(_ source: URL, paths: Set<String>, password: String?, kind: JobKind = .extract) {
        var job = ExtractionJob(source: ArchiveVolumes.firstVolume(for: source), compressedSize: Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        job.options = currentOptions; job.options.selectedPaths = paths; job.kind = kind
        if let password { remember(password, source: job.source) }
        jobs.append(job); queueStarted = true; schedule()
    }
    func test(_ source: URL) { enqueueSelection(source, paths: [], password: passwordFor(source), kind: .test) }
    func pause(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].state == .running { tokens[id]?.pause(); jobs[i].state = .paused }
        else if jobs[i].state == .paused { tokens[id]?.resume(); jobs[i].state = .running }
    }
    func resolveConflict(_ policy: ConflictPolicy, id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].options.conflictPolicy = policy; jobs[i].state = .queued; jobs[i].error = nil; queueStarted = true; schedule()
    }
    private var activeID: UUID?
    private var tokens: [UUID: CancellationToken] = [:]
    // One archive at a time: no competition for SSD bandwidth or thermal budget.
    // Utility QoS gives interactive apps priority without an arbitrary speed cap.
    private let worker = DispatchQueue(label: "app.quickunzip.extract", qos: .utility)

    var visibleJobs: [ExtractionJob] {
        jobs.filter { filter == .all || (filter == .active && !$0.state.isFinished) || (filter == .completed && $0.state == .done) }
    }
    var pendingCount: Int { jobs.filter { !$0.state.isFinished }.count }
    var completedCount: Int { jobs.filter { $0.state == .done }.count }
    var running: Bool { activeID != nil }
    var passwordJob: ExtractionJob? { jobs.first { $0.state == .needsPassword } }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择压缩文件"
        panel.prompt = "加入解压队列"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Intentionally no extension filter: renamed archives must work too.
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "选择解压输出位置"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择文件夹"
        if panel.runModal() == .OK { destination = panel.url }
    }

    func add(_ urls: [URL], layoutOverride: ExtractionLayout? = nil) {
        for raw in urls where raw.isFileURL {
            let url = ArchiveVolumes.firstVolume(for: raw)
            if jobs.contains(where: { $0.source.standardizedFileURL == url.standardizedFileURL && !$0.state.isFinished }) { continue }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            var job = ExtractionJob(source: url, compressedSize: size)
            job.options = currentOptions
            if let layoutOverride { job.options.layout = layoutOverride }
            jobs.append(job)
        }
        filter = .all
        saveHistory()
        if autoExtract { queueStarted = true; schedule() }
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty else { return false }
        // A group preserves Finder's order even when providers load out of order.
        let group = DispatchGroup()
        let collected = DropCollection()
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? URL { url = value }
                else { url = nil }
                if let url { collected.insert(url, at: index) }
            }
        }
        group.notify(queue: .main) { self.add(collected.urls) }
        return true
    }

    func startQueue() { queueStarted = true; schedule() }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].state == .running || jobs[index].state == .paused { tokens[id]?.cancel() }
        else if !jobs[index].state.isFinished { jobs[index].state = .cancelled; schedule() }
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .running else { return }
        jobs[index].state = .queued
        jobs[index].progress = 0
        jobs[index].bytesWritten = 0
        jobs[index].error = nil
        jobs[index].result = nil
        jobs[index].integrity = nil
        queueStarted = true
        schedule()
    }

    func submitPassword(_ password: String, for id: UUID) {
        guard activeID == nil, let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .needsPassword else { return }
        run(index: index, password: password)
    }

    func clearFinished() { jobs.removeAll { $0.state.isFinished }; saveHistory() }
    func reveal(_ result: ExtractionResult) { NSWorkspace.shared.activateFileViewerSelecting(result.outputs.isEmpty ? [result.destination] : result.outputs) }

    private func schedule() {
        guard activeID == nil, queueStarted || autoExtract else { return }
        // Password requests pause the queue until the user enters or cancels.
        guard passwordJob == nil, conflictJob == nil else { return }
        if let index = jobs.firstIndex(where: { $0.state == .queued }) { run(index: index, password: passwordFor(jobs[index].source)) }
    }

    private func run(index: Int, password: String?) {
        let id = jobs[index].id
        let source = jobs[index].source
        let parent = destination ?? source.deletingLastPathComponent()
        let encoding = encoding
        let options = jobs[index].options
        let kind = jobs[index].kind
        let token = CancellationToken()
        tokens[id] = token
        activeID = id
        jobs[index].state = .running
        jobs[index].startedAt = Date()
        jobs[index].error = nil
        worker.async {
            if kind == .test {
                let result = Result { try ArchiveEngine.testIntegrity(source: source, password: password, encoding: encoding, token: token) { update in DispatchQueue.main.async { self.update(id, progress: update) } } }
                DispatchQueue.main.async { self.finishTest(id, result: result, password: password) }
                return
            }
            let result = Result {
                try ArchiveEngine.extract(source: source, destinationParent: parent, password: password, encoding: encoding, token: token, options: options) { update in
                    DispatchQueue.main.async { self.update(id, progress: update) }
                }
            }
            DispatchQueue.main.async { self.finish(id, result: result, password: password) }
        }
    }

    private func update(_ id: UUID, progress: ExtractionProgress) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), (jobs[index].state == .running || jobs[index].state == .paused) else { return }
        jobs[index].format = progress.format
        jobs[index].progress = progress.fraction
        jobs[index].currentFile = progress.filename
        jobs[index].bytesWritten = progress.bytesWritten
        jobs[index].files = progress.files
    }

    private func finish(_ id: UUID, result: Result<ExtractionResult, Error>, password: String?) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        activeID = nil
        tokens.removeValue(forKey: id)
        switch result {
        case .success(let value):
            jobs[index].result = value
            jobs[index].format = value.format
            jobs[index].progress = 1
            jobs[index].bytesWritten = value.bytesWritten
            jobs[index].files = value.files
            jobs[index].state = .done
            if let password { remember(password, source: jobs[index].source) }
            if revealWhenDone { reveal(value) }
        case .failure(let error):
            if case ArchiveFailure.passwordRequired = error { jobs[index].state = .needsPassword }
            else if case ArchiveFailure.wrongPassword = error { jobs[index].state = .needsPassword; jobs[index].error = error.localizedDescription }
            else if case ArchiveFailure.conflict(let paths) = error { jobs[index].state = .needsConflict; jobs[index].conflicts = paths; if let password { remember(password, source: jobs[index].source) } }
            else if case ArchiveFailure.cancelled = error { jobs[index].state = .cancelled }
            else { jobs[index].state = .failed; jobs[index].error = error.localizedDescription }
        }
        saveHistory()
        schedule()
    }

    private func finishTest(_ id: UUID, result: Result<IntegrityResult, Error>, password: String?) {
        switch result {
        case .success(let value):
            activeID = nil; tokens.removeValue(forKey: id)
            if let i = jobs.firstIndex(where: { $0.id == id }) {
                jobs[i].state = .done; jobs[i].integrity = value; jobs[i].format = value.format; jobs[i].files = value.files; jobs[i].progress = 1
                if let password { remember(password, source: jobs[i].source) }
            }
            saveHistory(); schedule()
        case .failure(let error): finish(id, result: .failure(error), password: password)
        }
    }
    private struct History: Codable {
        let source: String; let destination: String?; let size: Int64; let format: String; let files: Int; let bytes: Int64; let duration: Double; let error: String?; let tested: Bool
    }
    init() {
        guard let data = UserDefaults.standard.data(forKey: "history.v2"), let history = try? JSONDecoder().decode([History].self, from: data) else { return }
        jobs = history.map { item in
            var job = ExtractionJob(source: URL(fileURLWithPath: item.source), compressedSize: item.size)
            job.format = item.format; job.files = item.files; job.error = item.error; job.state = item.error == nil ? .done : .failed
            if let dest = item.destination { job.result = ExtractionResult(destination: URL(fileURLWithPath: dest), format: item.format, files: item.files, bytesWritten: item.bytes, duration: item.duration) }
            if item.tested { job.kind = .test; job.integrity = IntegrityResult(format: item.format, files: item.files, bytesRead: item.bytes, duration: item.duration) }
            return job
        }
    }
    private func saveHistory() {
        let items = jobs.filter { $0.state == .done || $0.state == .failed }.suffix(40).map { job in
            History(source: job.source.path, destination: job.result?.destination.path, size: job.compressedSize, format: job.format, files: job.files, bytes: job.result?.bytesWritten ?? job.integrity?.bytesRead ?? 0, duration: job.result?.duration ?? job.integrity?.duration ?? 0, error: job.error, tested: job.kind == .test)
        }
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: "history.v2") }
    }
}

private final class DropCollection: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int: URL] = [:]
    func insert(_ url: URL, at index: Int) { lock.lock(); items[index] = url; lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return items.sorted { $0.key < $1.key }.map(\.value) }
}

func byteString(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
