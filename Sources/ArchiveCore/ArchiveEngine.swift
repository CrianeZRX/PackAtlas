import Foundation
import CoreFoundation
import Darwin
import CArchive

public enum ArchiveFailure: LocalizedError {
    case message(String), passwordRequired, wrongPassword, cancelled, conflict([String])
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .passwordRequired: return "此压缩包需要密码。"
        case .wrongPassword: return "密码不正确，请重试。"
        case .cancelled: return "已取消解压。"
        case .conflict(let names): return "输出位置存在同名文件：" + names.prefix(5).joined(separator: "、")
        }
    }
}

public final class CancellationToken: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private var paused = false
    public init() {}
    public var isPaused: Bool { condition.lock(); defer { condition.unlock() }; return paused }
    public func pause() { condition.lock(); paused = true; condition.unlock() }
    public func resume() { condition.lock(); paused = false; condition.broadcast(); condition.unlock() }
    public func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
    public func check() throws {
        condition.lock()
        while paused && !cancelled { condition.wait() }
        let value = cancelled
        condition.unlock()
        if value { throw ArchiveFailure.cancelled }
    }
}

public struct ExtractionProgress: Sendable {
    public let format: String
    public let filename: String
    public let fraction: Double
    public let bytesWritten: Int64
    public let files: Int
}

public struct ExtractionResult: Sendable {
    public let destination: URL
    public let format: String
    public let files: Int
    public let bytesWritten: Int64
    public let duration: TimeInterval
    public var outputs: [URL] = []
    public var skippedFiles: Int = 0
    public init(destination: URL, format: String, files: Int, bytesWritten: Int64, duration: TimeInterval) {
        self.destination = destination; self.format = format; self.files = files; self.bytesWritten = bytesWritten; self.duration = duration
    }
}

public struct ArchiveItem: Identifiable, Sendable {
    public let id: Int
    public let path: String
    public let size: Int64
    public let isDirectory: Bool
}

public struct ArchivePreview: Sendable {
    public let format: String
    public let items: [ArchiveItem]
    public let isTruncated: Bool
    public var comment: String? = nil
}

public enum FilenameEncoding: String, CaseIterable, Sendable {
    case automatic = "自动识别", gb18030 = "简体中文 GB18030", big5 = "繁体中文 Big5", japanese = "日文 Shift-JIS", korean = "韩文 CP949", utf8 = "UTF-8"
    var sevenZipArguments: [String] {
        switch self {
        case .automatic: return []
        case .gb18030: return ["-mcp=936"]
        case .big5: return ["-mcp=950"]
        case .japanese: return ["-mcp=932"]
        case .korean: return ["-mcp=949"]
        case .utf8: return ["-mcp=65001"]
        }
    }
    var option: String? {
        switch self {
        case .automatic: return nil
        case .gb18030: return "hdrcharset=GB18030"
        case .big5: return "hdrcharset=BIG5"
        case .japanese: return "hdrcharset=CP932"
        case .korean: return "hdrcharset=CP949"
        case .utf8: return "hdrcharset=UTF-8"
        }
    }
}

public enum ArchiveEngine {
    public static let supportedExtensions = ["zip", "zipx", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst", "lzma", "cab", "cpio", "iso", "xar", "a", "ar", "Z", "arj", "lzh", "lha", "chm", "dmg", "wim", "swm", "vhd", "vhdx", "udf", "deb", "rpm", "001", "egg", "alz", "ace", "pma", "zpaq", "isz", "bh", "aes", "uu", "uue", "xxe", "br", "lzfse", "lz", "lz4", "xpi", "jar"]
    public static var version: String { String(cString: archive_version_string()) }
    public static var hasExtendedEngine: Bool { SevenZipBackend.executable != nil }
    public static var decoderDescription: String {
        guard let url = SevenZipBackend.executable else { return "仅系统 libarchive" }
        return url.lastPathComponent == "7zz" ? "7-Zip 7zz · 现代引擎" : "p7zip 17.05 · 旧版兼容引擎"
    }

    public static func importDecoder(from source: URL) throws {
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ArchiveFailure.message("请选择官方下载包中的 7zz 可执行文件。") }
        let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 4096) ?? Data()
        let arm64: [UInt8] = [0x0c, 0x00, 0x00, 0x01]
        let isArm = prefix.count >= 8 && prefix.starts(with: [0xcf, 0xfa, 0xed, 0xfe]) && prefix[4..<8].elementsEqual(arm64)
        let isUniversal = prefix.count >= 8 && prefix.starts(with: [0xca, 0xfe, 0xba, 0xbe])
        guard isArm || isUniversal else { throw ArchiveFailure.message("文件不是兼容的 macOS Apple Silicon 可执行文件。请先解开官方 tar.xz 下载包，再选择其中的 7zz。") }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("QuickUnzip/Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".7zz-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        guard rename(temporary.path, directory.appendingPathComponent("7zz").path) == 0 else { throw ArchiveFailure.message("无法保存新解码器。") }
    }

    public static func detectedFormat(source: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: source) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 64) else { return nil }
        let signatures: [([UInt8], String)] = [
            ([0x52,0x61,0x72,0x21,0x1a,0x07,0x01,0x00], "RAR 5"),
            ([0x52,0x61,0x72,0x21,0x1a,0x07,0x00], "RAR"),
            ([0x37,0x7a,0xbc,0xaf,0x27,0x1c], "7-Zip"),
            ([0x50,0x4b,0x03,0x04], "ZIP"), ([0x50,0x4b,0x05,0x06], "ZIP"),
            ([0x1f,0x8b], "GZIP"), ([0x42,0x5a,0x68], "BZIP2"),
            ([0xfd,0x37,0x7a,0x58,0x5a,0x00], "XZ"),
            ([0x04,0x22,0x4d,0x18], "LZ4"), ([0x4c,0x5a,0x49,0x50], "LZIP"), ([0x28,0xb5,0x2f,0xfd], "Zstandard"), ([0x4d,0x53,0x43,0x46], "CAB")
        ]
        if let sig = signatures.first(where: { data.starts(with: $0.0) }) { return sig.1 }
        if let legacy = LegacyArchive.format(data, extension: source.pathExtension.lowercased()) { return legacy }
        let ext = source.pathExtension.lowercased()
        if ext == "br" { return "Brotli" }
        if ext == "zpaq" { return "ZPAQ" }
        return nil
    }

    private static func fail(_ reader: OpaquePointer, password: String?) -> ArchiveFailure {
        let detail = archive_error_string(reader).map { String(cString: $0) } ?? "无法读取压缩包。"
        let lower = detail.lowercased()
        if lower.contains("passphrase") || lower.contains("password") {
            return password == nil ? .passwordRequired : .wrongPassword
        }
        if lower.contains("encrypted") || lower.contains("encryption") {
            return .message("此压缩包使用了当前引擎不支持的加密方式。\n\(detail)")
        }
        return .message("无法解压，文件可能损坏或格式不受支持。\n\(detail)")
    }

    private static func open(_ source: URL, password: String?, encoding: FilenameEncoding) throws -> OpaquePointer {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ArchiveFailure.message("请选择压缩文件，暂不支持直接解压文件夹。") }
        guard let reader = archive_read_new() else { throw ArchiveFailure.message("无法初始化解压引擎。") }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        // Raw is enabled only for known compressor signatures. Otherwise any
        // arbitrary text file would falsely be accepted as an archive.
        let handle = try? FileHandle(forReadingFrom: source)
        let prefix = (try? handle?.read(upToCount: 8)) ?? Data()
        try? handle?.close()
        let magics: [[UInt8]] = [[0x1f,0x8b], [0x42,0x5a,0x68], [0xfd,0x37,0x7a,0x58,0x5a,0x00], [0x28,0xb5,0x2f,0xfd], [0x1f,0x9d], [0x04,0x22,0x4d,0x18], [0x4c,0x5a,0x49,0x50]]
        if magics.contains(where: { prefix.starts(with: $0) }) { archive_read_support_format_raw(reader) }
        if let option = encoding.option { archive_read_set_options(reader, option) }
        if let password { archive_read_add_passphrase(reader, password) }
        if archive_read_open_filename(reader, source.path, 256 * 1024) != ARCHIVE_OK {
            let error = fail(reader, password: password); archive_read_free(reader); throw error
        }
        return reader
    }

    private static func formatName(_ reader: OpaquePointer) -> String {
        let base = archive_format_name(reader).map { String(cString: $0) } ?? "Archive"
        let filters = (0..<archive_filter_count(reader)).compactMap { index -> String? in
            guard let name = archive_filter_name(reader, index) else { return nil }
            let text = String(cString: name)
            return text == "none" ? nil : text
        }
        return ([base] + filters).joined(separator: " · ")
    }

    private static func pathname(_ entry: OpaquePointer) throws -> String {
        if let utf8 = archive_entry_pathname_utf8(entry), let value = String(validatingCString: utf8) { return value }
        if let raw = archive_entry_pathname(entry) {
            if let value = String(validatingCString: raw) { return value }
            let bytes = Data(bytes: raw, count: strlen(raw))
            let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            if let value = String(data: bytes, encoding: gb) { return value }
        }
        throw ArchiveFailure.message("无法识别文件名编码。请在设置中切换中文编码后重试。")
    }

    // Independent of the extension and of the archive's own path interpretation.
    public static func safeRelativePath(_ path: String) throws -> String {
        let path = path.replacingOccurrences(of: "\\", with: "/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !path.contains("\0"),
              !parts.contains(".."), parts.first?.contains(":") != true else {
            throw ArchiveFailure.message("压缩包包含不安全路径，已停止：\(path)")
        }
        return parts.filter { $0 != "." }.joined(separator: "/")
    }

    static func safeLinkTarget(path: String, target: String) throws -> String {
        guard !target.hasPrefix("/"), !target.contains("\\"), !target.contains("\0"), !target.contains(":") else { throw ArchiveFailure.message("不安全的链接目标：\(path)") }
        var parts = path.split(separator: "/").dropLast().map(String.init)
        for part in target.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { throw ArchiveFailure.message("链接目标越过解压目录：\(path)") }
                parts.removeLast()
            } else { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }

    public static func outputName(for source: URL) -> String {
        let name = source.lastPathComponent
        if let suffix = name.range(of: #"(?i)\.part0*1\.isz$"#, options: .regularExpression), suffix.lowerBound != name.startIndex,
           detectedFormat(source: source) == "ISZ" { return String(name[..<suffix.lowerBound]) }
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma"] {
            if name.lowercased().hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        }
        let stem = source.deletingPathExtension().lastPathComponent
        return stem.isEmpty || stem == "." || stem == ".." ? "已解压文件" : stem
    }

    public static func preview(source: URL, encoding: FilenameEncoding = .automatic, limit: Int = 10000, password: String? = nil, token: CancellationToken = CancellationToken()) throws -> ArchivePreview {
        do {
            var result = try previewNative(source: source, encoding: encoding, limit: limit, password: password, token: token)
            result.comment = zipComment(source)
            return result
        }
        catch let ArchiveFailure.message(detail) where hasExtendedEngine && needsExtendedReader(detail) {
            return try SevenZipBackend.preview(source: ArchiveVolumes.firstVolume(for: source), password: password, limit: limit, encoding: encoding, token: token)
        }
    }

    private static func needsExtendedReader(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        return ["unsupported", "not supported", "unrecognized archive"].contains(where: lower.contains)
    }

    private static func zipComment(_ source: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: source) else { return nil }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd(), length >= 22 else { return nil }
        try? handle.seek(toOffset: length - min(length, 65_557))
        guard let data = try? handle.readToEnd(), data.count >= 22 else { return nil }
        for i in stride(from: data.count - 22, through: 0, by: -1) {
            guard data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 5, data[i + 3] == 6 else { continue }
            let size = Int(data[i + 20]) | Int(data[i + 21]) << 8
            if size > 0 && i + 22 + size == data.count {
                let bytes = data.subdata(in: i + 22..<data.count)
                return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1)
            }
        }
        return nil
    }

    private static func previewNative(source: URL, encoding: FilenameEncoding, limit: Int, password: String?, token: CancellationToken) throws -> ArchivePreview {
        let source = ArchiveVolumes.firstVolume(for: source)
        let signature = detectedFormat(source: source) ?? ""
        if LegacyArchive.formats.contains(signature) {
            let r = try LegacyArchive.run("list", format: signature, source: source, password: password, encoding: encoding, token: token, limit: limit)
            return ArchivePreview(format: signature, items: r.items.enumerated().map { ArchiveItem(id: $0.offset, path: $0.element.path, size: $0.element.size, isDirectory: $0.element.directory) }, isTruncated: r.truncated)
        }
        if hasExtendedEngine && (signature.hasPrefix("RAR") || signature == "7-Zip") {
            return try SevenZipBackend.preview(source: source, password: password, limit: limit, encoding: encoding, token: token)
        }
        let reader = try open(source, password: password, encoding: encoding)
        defer { archive_read_free(reader) }
        var items: [ArchiveItem] = []
        while true {
            try token.check()
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else { throw fail(reader, password: password) }
            if items.count == limit { return ArchivePreview(format: formatName(reader), items: items, isTruncated: true) }
            items.append(ArchiveItem(id: items.count, path: try pathname(entry), size: max(0, archive_entry_size(entry)), isDirectory: archive_entry_filetype(entry) == S_IFDIR))
            // Some solid formats must decompress to advance; the preview is
            // bounded by the caller and runs off the main thread.
            if archive_read_data_skip(reader) < ARCHIVE_WARN { throw fail(reader, password: password) }
        }
        return ArchivePreview(format: formatName(reader), items: items, isTruncated: false)
    }

    public static func extract(source: URL, destinationParent: URL, password: String? = nil,
                               encoding: FilenameEncoding = .automatic, token: CancellationToken = CancellationToken(),
                               options: ExtractionOptions = ExtractionOptions(),
                               progress: @escaping (ExtractionProgress) -> Void = { _ in }) throws -> ExtractionResult {
        let source = ArchiveVolumes.firstVolume(for: source)
        let parent = destinationParent.resolvingSymlinksInPath()
        let workspace = parent.appendingPathComponent(".quickunzip-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            if !FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".preserve-backup").path) { try? FileManager.default.removeItem(at: workspace) }
        }
        let start = Date()
        let raw = try decode(source: source, destinationParent: workspace, password: password, encoding: encoding, token: token, options: options, progress: progress)
        let published = try OutputPublisher.publish(payload: raw.destination, parent: parent, archiveName: outputName(for: source), options: options, token: token, workspace: workspace)
        var result = ExtractionResult(destination: published.destination, format: raw.format, files: raw.files, bytesWritten: raw.bytesWritten, duration: Date().timeIntervalSince(start))
        result.outputs = published.outputs
        result.skippedFiles = published.skipped
        return result
    }

    private static func decode(source: URL, destinationParent: URL, password: String?, encoding: FilenameEncoding,
                               token: CancellationToken, options: ExtractionOptions,
                               progress: @escaping (ExtractionProgress) -> Void) throws -> ExtractionResult {
        let format = detectedFormat(source: source) ?? "自动识别"
        progress(ExtractionProgress(format: format, filename: "正在读取压缩包…", fraction: 0, bytesWritten: 0, files: 0))
        if LegacyArchive.formats.contains(format) {
            let start = Date()
            let payload = destinationParent.appendingPathComponent("payload")
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let r = try LegacyArchive.run("extract", format: format, source: source, destination: payload, password: password, encoding: encoding, token: token, options: options)
            progress(ExtractionProgress(format: format, filename: "完成", fraction: 1, bytesWritten: r.size, files: r.files))
            return ExtractionResult(destination: payload, format: format, files: r.files, bytesWritten: r.size, duration: Date().timeIntervalSince(start))
        }
        if format.hasPrefix("ZIP"), encoding == .automatic,
           let result = try ParallelZIP.extractIfEligible(source: source, destinationParent: destinationParent, token: token, options: options, progress: progress) { return result }
        if hasExtendedEngine && (format.hasPrefix("RAR") || format == "7-Zip") {
            return try SevenZipBackend.extract(source: source, destinationParent: destinationParent, password: password, token: token, options: options, encoding: encoding, progress: progress)
        }
        do {
            return try extractNative(source: source, destinationParent: destinationParent, password: password, encoding: encoding, token: token, options: options, progress: progress)
        } catch let ArchiveFailure.message(detail) where hasExtendedEngine &&
            needsExtendedReader(detail) {
            return try SevenZipBackend.extract(source: source, destinationParent: destinationParent, password: password, token: token, options: options, encoding: encoding, progress: progress)
        }
    }

    private static func extractNative(source: URL, destinationParent: URL, password: String?,
                                      encoding: FilenameEncoding, token: CancellationToken, options: ExtractionOptions,
                                      progress: @escaping (ExtractionProgress) -> Void) throws -> ExtractionResult {
        let start = Date()
        try token.check()
        let reader = try open(source, password: password, encoding: encoding)
        defer { archive_read_free(reader) }
        let fm = FileManager.default
        let parent = destinationParent.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ArchiveFailure.message("输出文件夹不存在，请重新选择。")
        }
        let stage = parent.appendingPathComponent(".quickunzip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let inputSize = max(1, (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 1)
        let capacity = (try? parent.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init) ?? Int64.max
        var bytes: Int64 = 0, files = 0, announced: Int64 = 0
        var symbolicLinks: [(String, String)] = [], hardLinks: [(String, String)] = []
        var lastReport = Date.distantPast
        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            try token.check()
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else { throw fail(reader, password: password) }
            // Do not publish a partial archive when libarchive reports warnings.
            if status == ARCHIVE_WARN {
                let detail = archive_error_string(reader).map { String(cString: $0) } ?? "压缩包头部异常"
                // Non-UTF8 locale conversion can warn even though the raw name is recoverable.
                if !detail.lowercased().contains("convert") { throw fail(reader, password: password) }
            }
            let format = formatName(reader)
            let isRaw = archive_format(reader) == ARCHIVE_FORMAT_RAW
            let name = try safeRelativePath(isRaw ? outputName(for: source) : pathname(entry))
            if name.isEmpty { continue }
            if !options.includes(name) {
                if archive_read_data_skip(reader) < ARCHIVE_WARN { throw fail(reader, password: password) }
                continue
            }
            let kind = archive_entry_filetype(entry)
            if let link = archive_entry_symlink(entry) {
                let target = String(cString: link)
                _ = try safeLinkTarget(path: name, target: target)
                symbolicLinks.append((name, target))
                if archive_read_data_skip(reader) < ARCHIVE_WARN { throw fail(reader, password: password) }
                continue
            }
            if let link = archive_entry_hardlink(entry) {
                hardLinks.append((name, try safeRelativePath(String(cString: link))))
                if archive_read_data_skip(reader) < ARCHIVE_WARN { throw fail(reader, password: password) }
                continue
            }
            guard kind == S_IFREG || kind == S_IFDIR else {
                throw ArchiveFailure.message("压缩包包含链接或特殊文件，已停止：\(name)")
            }
            if archive_entry_is_encrypted(entry) == 1, password == nil { throw ArchiveFailure.passwordRequired }
            let declared = max(0, archive_entry_size(entry))
            let sum = announced.addingReportingOverflow(declared)
            guard !sum.overflow, sum.partialValue <= capacity else { throw ArchiveFailure.message("可用磁盘空间不足。") }
            announced = sum.partialValue
            let target = stage.appendingPathComponent(name)
            if kind == S_IFDIR {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // All links are rejected. O_EXCL also rejects duplicate members and
            // case-insensitive collisions rather than silently replacing data.
            let fd = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw ArchiveFailure.message("无法创建文件（可能重名或无权限）：\(name)\n\(String(cString: strerror(errno)))") }
            do {
                while true {
                    try token.check()
                    let count = archive_read_data(reader, buffer, bufferSize)
                    if count == 0 { break }
                    if count < 0 { throw fail(reader, password: password) }
                    guard bytes <= capacity - Int64(count) else { throw ArchiveFailure.message("可用磁盘空间不足。") }
                    var offset = 0
                    while offset < count {
                        let n = Darwin.write(fd, buffer.advanced(by: offset), count - offset)
                        if n < 0 && errno == EINTR { continue }
                        guard n > 0 else { throw ArchiveFailure.message("写入失败：\(String(cString: strerror(errno)))") }
                        offset += n
                    }
                    bytes += Int64(count)
                    if options.performance == .background { usleep(1_000) }
                    // Utility QoS already yields CPU to interactive work. Apply
                    // a small additional delay only during thermal pressure.
                    switch ProcessInfo.processInfo.thermalState {
                    case .serious: usleep(2_000)
                    case .critical: usleep(10_000)
                    default: break
                    }
                    if Date().timeIntervalSince(lastReport) > 0.08 {
                        let fraction = min(0.99, max(0, Double(archive_filter_bytes(reader, -1)) / Double(inputSize)))
                        progress(ExtractionProgress(format: format, filename: name, fraction: fraction, bytesWritten: bytes, files: files))
                        lastReport = Date()
                    }
                }
                let mode: mode_t = archive_entry_perm(entry) & 0o111 != 0 ? 0o755 : 0o644
                if options.preserveTimestamps && archive_entry_mtime_is_set(entry) != 0 {
                    var times = [timespec(tv_sec: archive_entry_mtime(entry), tv_nsec: archive_entry_mtime_nsec(entry)), timespec(tv_sec: archive_entry_mtime(entry), tv_nsec: archive_entry_mtime_nsec(entry))]
                    _ = futimens(fd, &times)
                }
                if fchmod(fd, mode) != 0 { throw ArchiveFailure.message("无法设置输出文件权限。") }
                if Darwin.close(fd) != 0 { throw ArchiveFailure.message("无法完成文件写入。") }
            } catch {
                Darwin.close(fd)
                throw error
            }
            files += 1
        }
        try token.check()
        // All data is written before links exist, so an archive link can never
        // redirect a later write. Targets must resolve to extracted content.
        for (path, target) in hardLinks {
            let original = stage.appendingPathComponent(target)
            var info = stat()
            guard lstat(original.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ArchiveFailure.message("硬链接目标不是已解压的普通文件：\(path)") }
            let output = stage.appendingPathComponent(path)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard Darwin.link(original.path, output.path) == 0 else { throw ArchiveFailure.message("无法创建硬链接：\(path)") }
            files += 1
        }
        for (path, target) in symbolicLinks {
            let output = stage.appendingPathComponent(path)
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard Darwin.symlink(target, output.path) == 0 else { throw ArchiveFailure.message("链接与已有文件冲突：\(path)") }
        }
        for (path, _) in symbolicLinks {
            let resolved = stage.appendingPathComponent(path).resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(stage.path + "/"), fm.fileExists(atPath: resolved.path) else { throw ArchiveFailure.message("链接未指向解压目录内的有效文件：\(path)") }
            files += 1
        }
        if !options.selectedPaths.isEmpty && files == 0 && (try? fm.contentsOfDirectory(atPath: stage.path).isEmpty) == true { throw ArchiveFailure.message("未找到选中的文件。") }
        let format = formatName(reader)
        // Atomic rename without replacement, including between concurrent jobs.
        let stem = outputName(for: source)
        for index in 0..<10000 {
            let name = index == 0 ? stem : "\(stem) (\(index + 1))"
            let destination = parent.appendingPathComponent(name, isDirectory: true)
            let result = renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL))
            if result == 0 {
                progress(ExtractionProgress(format: format, filename: "完成", fraction: 1, bytesWritten: bytes, files: files))
                return ExtractionResult(destination: destination, format: format, files: files, bytesWritten: bytes, duration: Date().timeIntervalSince(start))
            }
            if errno != EEXIST && errno != ENOTEMPTY { throw ArchiveFailure.message("无法保存解压结果：\(String(cString: strerror(errno)))") }
        }
        throw ArchiveFailure.message("同名文件夹过多，请更换输出位置。")
    }
    public static func testIntegrity(source: URL, password: String? = nil, encoding: FilenameEncoding = .automatic,
                                     token: CancellationToken = CancellationToken(),
                                     progress: @escaping (ExtractionProgress) -> Void = { _ in }) throws -> IntegrityResult {
        let source = ArchiveVolumes.firstVolume(for: source)
        let signature = detectedFormat(source: source) ?? ""
        if LegacyArchive.formats.contains(signature) {
            let start = Date()
            let r = try LegacyArchive.run("test", format: signature, source: source, password: password, encoding: encoding, token: token)
            return IntegrityResult(format: signature, files: r.files, bytesRead: r.size, duration: Date().timeIntervalSince(start))
        }
        if hasExtendedEngine && (signature.hasPrefix("RAR") || signature == "7-Zip") {
            return try SevenZipBackend.test(source: source, password: password, encoding: encoding, token: token, progress: progress)
        }
        do {
            return try testNative(source: source, password: password, encoding: encoding, token: token, progress: progress)
        } catch let ArchiveFailure.message(detail) where hasExtendedEngine && needsExtendedReader(detail) {
            return try SevenZipBackend.test(source: source, password: password, encoding: encoding, token: token, progress: progress)
        }
    }

    private static func testNative(source: URL, password: String?, encoding: FilenameEncoding,
                                   token: CancellationToken, progress: (ExtractionProgress) -> Void) throws -> IntegrityResult {
        let start = Date()
        let reader = try open(source, password: password, encoding: encoding)
        defer { archive_read_free(reader) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1024 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        let inputSize = max(1, Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1))
        var bytes: Int64 = 0, files = 0
        var report = Date.distantPast
        while true {
            try token.check()
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else { throw fail(reader, password: password) }
            while true {
                try token.check()
                let count = archive_read_data(reader, buffer, 1024 * 1024)
                if count == 0 { break }
                if count < 0 { throw fail(reader, password: password) }
                bytes += Int64(count)
                if Date().timeIntervalSince(report) > 0.1 {
                    progress(ExtractionProgress(format: formatName(reader), filename: try pathname(entry), fraction: min(0.99, Double(archive_filter_bytes(reader, -1)) / Double(inputSize)), bytesWritten: bytes, files: files))
                    report = Date()
                }
            }
            if archive_entry_filetype(entry) == S_IFREG { files += 1 }
        }
        return IntegrityResult(format: formatName(reader), files: files, bytesRead: bytes, duration: Date().timeIntervalSince(start))
    }

}
