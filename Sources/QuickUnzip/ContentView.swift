import SwiftUI
import AppKit
import ArchiveCore

let ink = Color(red: 0.12, green: 0.19, blue: 0.18)
let accent = Color(red: 0.10, green: 0.43, blue: 0.35)
let canvas = Color(red: 0.97, green: 0.97, blue: 0.95)

struct ContentView: View {
    @ObservedObject var store: AppStore
    @State private var isTargeted = false
    @State private var password = ""
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 30).padding(.top, 38).padding(.bottom, 24)
                dropZone.padding(.horizontal, 30)
                queueHeader.padding(.horizontal, 30).padding(.top, 27).padding(.bottom, 13)
                if store.visibleJobs.isEmpty { emptyQueue }
                else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.visibleJobs) { job in JobRow(job: job, store: store) }
                        }.padding(.horizontal, 30).padding(.bottom, 20)
                    }
                }
                outputBar
            }.background(canvas)
        }
        .foregroundStyle(ink)
        .tint(accent)
        .preferredColorScheme(.light)
        .onDrop(of: ["public.file-url"], isTargeted: $isTargeted, perform: store.acceptDrop)
        .sheet(isPresented: $store.showsSettings) { SettingsView(store: store) }
        .sheet(item: $store.previewSource) { source in ArchiveBrowserView(source: source, store: store) }
        .sheet(isPresented: Binding(get: { store.passwordJob != nil }, set: { if !$0, let job = store.passwordJob { store.cancel(job.id) } })) {
            passwordSheet
        }
        .sheet(isPresented: Binding(get: { store.conflictJob != nil }, set: { if !$0, let job = store.conflictJob { store.cancel(job.id) } })) {
            if let job = store.conflictJob {
                VStack(alignment: .leading, spacing: 18) {
                    Label("发现同名文件", systemImage: "doc.on.doc").font(.title2)
                    Text(job.conflicts.prefix(8).joined(separator: "\n")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("为本次任务选择处理方式。选择替换后会先保留原文件备份，成功保存后再移除备份。").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    HStack { Button("取消") { store.cancel(job.id) }; Spacer(); ForEach([ConflictPolicy.skip, .rename, .replace], id: \.self) { policy in Button(policy.rawValue) { store.resolveConflict(policy, id: job.id) } } }
                }.padding(28).frame(width: 480)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill").font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.white).frame(width: 44, height: 44).background(accent, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("轻解").font(.system(size: 23, weight: .bold))
                    Text("QUICKUNZIP").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1.3).foregroundStyle(.secondary)
                }
            }.padding(.top, 47).padding(.bottom, 40)
            Text("工作空间").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 12).padding(.bottom, 13)
            ForEach(QueueFilter.allCases, id: \.self) { filter in
                Button { store.filter = filter } label: {
                    HStack(spacing: 10) {
                        Image(systemName: filter == .all ? "square.stack.3d.up" : filter == .active ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                            .frame(width: 18)
                        Text(filter.rawValue).font(.system(size: 12, weight: store.filter == filter ? .semibold : .regular))
                        Spacer()
                        let count = filter == .all ? store.jobs.count : filter == .active ? store.pendingCount : store.completedCount
                        Text("\(count)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 12).padding(.vertical, 12)
                        .background(store.filter == filter ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(store.filter == filter ? accent : ink.opacity(0.65))
                }.buttonStyle(.plain).padding(.bottom, 4)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 5, height: 5)
                    Text("本地处理 · 文件不上传").font(.system(size: 10, weight: .medium))
                }
                Text("一次专注一个文件\n为前台应用留出空间").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12)).padding(.bottom, 16)
            Button { store.showsSettings = true } label: {
                Label("偏好设置", systemImage: "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).padding(.bottom, 20)
        }.padding(.horizontal, 16).frame(width: 174)
            .background(Color(red: 0.93, green: 0.94, blue: 0.91))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 9) {
                Text("解压，轻而易举。").font(.system(size: 28, weight: .bold)).tracking(-0.8)
                Text("自动识别格式，把等待交给后台。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: store.chooseFiles) {
                Label("添加压缩文件", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 17).padding(.vertical, 12).foregroundStyle(.white)
                    .background(accent, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).keyboardShortcut("o").help("添加文件 ⌘O")
        }
    }

    private var dropZone: some View {
        Button(action: store.chooseFiles) {
            HStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 19).fill(accent.opacity(0.07)).frame(width: 82, height: 82).rotationEffect(.degrees(-8))
                    Image(systemName: "archivebox").font(.system(size: 35, weight: .light)).foregroundStyle(accent)
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 23)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, accent).offset(x: 25, y: 25)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text(isTargeted ? "松开，即刻开始。" : "把压缩文件拖到这里").font(.system(size: 18, weight: .semibold))
                    Text("或点击选择文件，支持一次添加多个压缩包").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(["ZIP", "7Z", "RAR", "TAR", "GZ", "更多"], id: \.self) { value in
                            Text(value).font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 4).background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(accent.opacity(0.8))
                        }
                    }.padding(.top, 5)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 29).padding(.vertical, 30).frame(maxWidth: .infinity, minHeight: 174)
                .background(isTargeted ? accent.opacity(0.07) : Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(accent.opacity(isTargeted ? 0.7 : 0.23), style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [5,5])))
        }.buttonStyle(.plain)
    }

    private var queueHeader: some View {
        HStack {
            Text(store.filter.rawValue).font(.system(size: 14, weight: .semibold))
            Text("\(store.visibleJobs.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.04), in: Capsule())
            Spacer()
            if !store.autoExtract && store.jobs.contains(where: { $0.state == .queued }) {
                Button("开始解压", action: store.startQueue).font(.system(size: 11, weight: .medium))
            }
            Button("清除已结束", action: store.clearFinished).font(.system(size: 10)).foregroundStyle(.secondary).buttonStyle(.plain)
                .disabled(!store.jobs.contains { $0.state.isFinished })
        }
    }

    private var emptyQueue: some View {
        VStack(spacing: 10) {
            Image(systemName: store.filter == .completed ? "checkmark.circle" : "tray").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(ink.opacity(0.25))
            Text(store.filter == .completed ? "完成的文件会出现在这里" : "准备好了，等待你的第一个文件").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("按 ⌘O 选择文件").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 30)
    }

    private var outputBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(ink.opacity(0.06)).frame(height: 1)
            HStack(spacing: 9) {
                Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("解压到").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text((store.destination?.path ?? "压缩文件所在位置") + " / " + store.layout.rawValue).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                Button("更改", action: store.chooseDestination).font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(accent).padding(.leading, 7)
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "leaf").font(.system(size: 11))
                    Text("智能调度").font(.system(size: 10))
                }.foregroundStyle(accent).padding(.horizontal, 10).padding(.vertical, 7).background(accent.opacity(0.065), in: Capsule())
            }.padding(.horizontal, 30).padding(.vertical, 18)
        }.background(.white.opacity(0.5))
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 17) {
            Image(systemName: "lock.shield").font(.system(size: 28)).foregroundStyle(accent)
            Text("输入压缩包密码").font(.system(size: 21, weight: .semibold))
            if let job = store.passwordJob {
                Text(job.source.lastPathComponent).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                SecureField("解压密码", text: $password).textFieldStyle(.roundedBorder)
                    .onSubmit { submitPassword() }
                if let integrity = job.integrity { Text("已完整读取 \(integrity.files) 个文件 · \(byteString(integrity.bytesRead)) · 无校验错误").font(.system(size: 10)).foregroundStyle(accent) }
                if let result = job.result, result.skippedFiles > 0 { Text("跳过 \(result.skippedFiles) 个同名条目").font(.system(size: 10)).foregroundStyle(.secondary) }
                if let error = job.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
                Text("密码仅用于本次解压，不保存到磁盘。").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Button("取消此任务") { store.cancel(job.id); password = "" }
                    Spacer()
                    Button("继续解压", action: submitPassword).buttonStyle(.borderedProminent).disabled(password.isEmpty).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(30).frame(width: 370).onDisappear { password = "" }
    }

    private func submitPassword() {
        if let job = store.passwordJob { store.submitPassword(password, for: job.id); password = "" }
    }
}

struct JobRow: View {
    let job: ExtractionJob
    @ObservedObject var store: AppStore
    var color: Color { job.state == .failed ? .red : job.state == .cancelled ? .gray : accent }
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack(alignment: .bottom) {
                Image(systemName: "doc.zipper").font(.system(size: 29, weight: .ultraLight)).foregroundStyle(color.opacity(0.65))
            }.frame(width: 39, height: 46).background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(job.source.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(job.kind == .test && job.state == .done ? "完整性测试通过" : job.state.title).font(.system(size: 9, weight: .medium)).foregroundStyle(color)
                    if job.state == .done { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(accent) }
                }
                HStack(spacing: 7) {
                    Text(job.format).lineLimit(1)
                    Text("·")
                    Text(byteString(job.compressedSize))
                    if let result = job.result {
                        Text("·")
                        Text("\(result.files) 个文件 · \(String(format: "%.2f", result.duration)) 秒")
                    }
                    Spacer()
                    if job.state == .running || job.state == .paused {
                        Text("\(byteString(Int64(job.bytesPerSecond)))/s").monospacedDigit()
                        Text("\(Int(job.progress * 100))%").monospacedDigit()
                    }
                }.font(.system(size: 9)).foregroundStyle(.secondary)
                if let actual = mismatchedFormat {
                    Label("实际格式为 \(actual)，与 .\(job.source.pathExtension) 后缀不同，已按内容识别", systemImage: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(accent)
                }
                if job.state == .running || job.state == .paused {
                    ProgressView(value: job.progress).progressViewStyle(.linear).tint(accent)
                    Text(job.currentFile.isEmpty ? "正在识别格式…" : job.currentFile).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                if let integrity = job.integrity { Text("已完整读取 \(integrity.files) 个文件 · \(byteString(integrity.bytesRead)) · 无校验错误").font(.system(size: 10)).foregroundStyle(accent) }
                if let result = job.result, result.skippedFiles > 0 { Text("跳过 \(result.skippedFiles) 个同名条目").font(.system(size: 10)).foregroundStyle(.secondary) }
                if let error = job.error { Text(error).font(.system(size: 10)).foregroundStyle(.red.opacity(0.85)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 14) {
                    if let result = job.result {
                        Button { store.reveal(result) } label: { Label("在 Finder 中显示", systemImage: "folder") }
                    } else if job.state == .failed || job.state == .cancelled {
                        Button { store.retry(job.id) } label: { Label("重试", systemImage: "arrow.clockwise") }
                    }
                    // Preview is disabled during extraction to avoid duplicate I/O.
                    Button { store.browse(job.source) } label: { Label("查看内容", systemImage: "list.bullet") }.disabled(store.running)
                    Button { store.test(job.source) } label: { Label("测试", systemImage: "checkmark.shield") }.disabled(store.running)
                    Spacer()
                    if job.state == .running || job.state == .paused { Button(job.state == .paused ? "继续" : "暂停") { store.pause(job.id) } }
                    if !job.state.isFinished { Button("取消") { store.cancel(job.id) }.foregroundStyle(.secondary) }
                }.font(.system(size: 9)).buttonStyle(.plain).foregroundStyle(accent).padding(.top, 2)
            }
        }.padding(15).background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ink.opacity(0.04)))
    }
    private var mismatchedFormat: String? {
        let ext = job.source.pathExtension.lowercased()
        if job.format.hasPrefix("RAR"), ext != "rar", ext.range(of: #"^r[0-9]{2}$"#, options: .regularExpression) == nil { return job.format.hasPrefix("RAR 5") ? "RAR 5" : "RAR" }
        if job.format.hasPrefix("7-Zip"), ext != "7z", ext != "001" { return "7z" }
        if job.format.hasPrefix("ZIP"), !["zip","zipx","jar","xpi","apk","ipa","epub","docx","pptx","xlsx"].contains(ext) { return "ZIP" }
        return nil
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("偏好设置").font(.system(size: 23, weight: .semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            Form {
                Section("解压") {
                    Toggle("加入后自动解压", isOn: $store.autoExtract)
                    Toggle("完成后在 Finder 中显示", isOn: $store.revealWhenDone)
                    Picker("输出方式", selection: $store.layout) { ForEach(ExtractionLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("同名文件", selection: $store.conflictPolicy) { ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Text("智能解压：单文件、单顶层文件夹直接释放；多个顶层条目放入同名文件夹。").font(.caption).foregroundStyle(.secondary)
                }
                Section("文件名与兼容性") {
                    Picker("文件名编码", selection: $store.encoding) { ForEach(FilenameEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("Unicode 规范化", selection: $store.normalization) { ForEach(UnicodeNormalization.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Toggle("忽略 __MACOSX、._ 和 .DS_Store", isOn: $store.ignoreMacMetadata)
                    Toggle("本次运行记住已输入的密码", isOn: $store.rememberPasswords)
                    Text("密码仅保存在内存。退出即清除；历史记录不包含密码。").font(.caption).foregroundStyle(.secondary)
                }
                Section("速度与系统响应") {
                    Picker("性能模式", selection: $store.performance) { ForEach(PerformanceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Text("均衡：最多 2 个解码线程；速度优先：最多 4 个；低占用：1 个。始终一次处理一个包，支持暂停。具体格式的并行能力由算法决定。").font(.caption).foregroundStyle(.secondary)
                }
                Section("解压引擎") {
                    Text(store.decoderDescription).font(.system(size: 11, weight: .medium))
                    HStack { Button("导入官方 7zz…", action: store.importDecoder); Link("官方下载页", destination: URL(string: "https://www.7-zip.org/download.html")!) }
                    if let note = store.decoderNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                    Text("已内置官方 7-Zip 26.06，支持 RAR 5。需要更新时，可从 macOS 下载包中选择 7zz。").font(.caption).foregroundStyle(.secondary)
                }
                Section("输出位置") {
                    Text(store.destination?.path ?? "压缩包所在位置").font(.system(size: 11)).textSelection(.enabled)
                    HStack { Button("选择文件夹…", action: store.chooseDestination); Button("恢复默认") { store.destination = nil } }
                }
                Text("轻解 2.0 · libarchive + 7-Zip\n可浏览、选中解压、测试完整性；分卷自动定位首卷。EGG / ALZ / ACE / ZPAQ 暂未覆盖。").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
        }.padding(25).frame(width: 540, height: 740).tint(accent)
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }
