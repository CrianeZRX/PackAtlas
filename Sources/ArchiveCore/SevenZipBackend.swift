import Foundation
import Darwin

// Kept in a subprocess so the decoder can be cancelled without blocking AppKit.
// Binary and codec library are bundled; Homebrew is never required at runtime.
enum SevenZipBackend {
    static var executable: URL? {
        let candidates: [URL?] = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("QuickUnzip/Tools/7zz"),
            Bundle.main.resourceURL?.appendingPathComponent("Tools/7zz"),
            Bundle.main.resourceURL?.appendingPathComponent("Tools/7z"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Tools/7zz"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Tools/7z"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/7zip/7zz"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/7zip/7z")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    struct Member {
        let path: String
        let size: Int64
        let directory: Bool
        let encrypted: Bool
    }
    struct Listing {
        let format: String
        let members: [Member]
    }

    private final class CapturedOutput: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var overflow = false
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if data.count + chunk.count > 32 * 1024 * 1024 { overflow = true }
            else { data.append(chunk) }
        }
        func snapshot() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (data, overflow) }
    }

    private static func command(_ args: [String], password: String?, token: CancellationToken,
                                onProgress: ((Double) -> Void)? = nil) throws -> String {
        guard let executable else { throw ArchiveFailure.message("缺少内置 7-Zip 引擎，请重新构建应用。") }
        try token.check()
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.qualityOfService = .utility
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        process.environment = environment
        let pipe = Pipe(), input = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = input
        let capture = CapturedOutput()
        try process.run()
        let readerFinished = DispatchGroup()
        readerFinished.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readerFinished.leave() }
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                capture.append(data)
            }
        }
        // Passphrases travel through stdin, never command-line arguments or disk.
        try? input.fileHandleForWriting.write(contentsOf: Data(((password ?? "") + "\n").utf8))
        try? input.fileHandleForWriting.close()
        var cancellation: Error?
        var lastPercent = -1
        let percentRegex = try NSRegularExpression(pattern: "([0-9]{1,3})%")
        while process.isRunning {
            if token.isPaused {
                kill(process.processIdentifier, SIGSTOP)
                do { try token.check() } catch { kill(process.processIdentifier, SIGCONT); cancellation = error; process.terminate(); break }
                kill(process.processIdentifier, SIGCONT)
            }
            do { try token.check() } catch { cancellation = error; process.terminate(); break }
            let (data, overflow) = capture.snapshot()
            if overflow { cancellation = ArchiveFailure.message("压缩包目录过大，已停止以限制内存占用。"); process.terminate(); break }
            if let onProgress, let text = String(data: data.suffix(4096), encoding: .utf8) {
                let matches = percentRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                if let match = matches.last, let range = Range(match.range(at: 1), in: text), let percent = Int(text[range]), percent != lastPercent {
                    lastPercent = percent; onProgress(min(0.99, Double(percent) / 100))
                }
            }
            Thread.sleep(forTimeInterval: 0.04)
        }
        if cancellation != nil {
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        readerFinished.wait()
        if let cancellation { throw cancellation }
        let (data, overflow) = capture.snapshot()
        if overflow { throw ArchiveFailure.message("压缩包目录过大。") }
        let text = String(decoding: data, as: UTF8.self)
        if process.terminationStatus != 0 {
            let lower = text.lowercased()
            if lower.contains("wrong password") || lower.contains("password is incorrect") || lower.contains("data error in encrypted") {
                throw password == nil ? ArchiveFailure.passwordRequired : ArchiveFailure.wrongPassword
            }
            if lower.contains("unsupported method") {
                throw ArchiveFailure.message("当前解码器不支持此压缩方法。请在偏好设置中导入新版官方 7zz，然后重试；这条错误本身不能证明文件损坏。")
            }
            // Do not expose entire file listings in the error UI.
            let detail = text.split(whereSeparator: \.isNewline).filter { $0.contains("ERROR") || $0.contains("Error") }.suffix(4).joined(separator: "\n")
            throw ArchiveFailure.message("7-Zip 无法解压此文件，可能损坏、缺少分卷或算法不受支持。\n\(detail)")
        }
        return text
    }

    private static func list(source: URL, password: String?, token: CancellationToken, encoding: FilenameEncoding = .automatic) throws -> Listing {
        let rawText = try command(["l", "-slt", "-sccUTF-8"] + encoding.sevenZipArguments + ["--", source.path], password: password, token: token)
        return try parseListing(rawText, source: source)
    }

    static func parseListing(_ rawText: String, source: URL) throws -> Listing {
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        guard let boundary = text.range(of: "----------\n") else { throw ArchiveFailure.message("无法读取 7-Zip 压缩包目录。") }
        let header = String(text[..<boundary.lowerBound])
        let rawType = header.split(separator: "\n").first { $0.hasPrefix("Type = ") }.map { String($0.dropFirst(7)) } ?? "Archive"
        let detected = ArchiveEngine.detectedFormat(source: source)
        let format = "\(detected ?? rawType) · 7-Zip"
        var members: [Member] = [], seen = Set<String>()
        for record in text[boundary.upperBound...].components(separatedBy: "\n\n") where !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var fields: [String: String] = [:]
            for line in record.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("Warnings: "), Int(line.dropFirst(10)) != nil { continue }
                guard let separator = line.range(of: " = ") else { throw ArchiveFailure.message("目录包含无法安全识别的文件名或字段。") }
                let key = String(line[..<separator.lowerBound])
                guard fields[key] == nil else { throw ArchiveFailure.message("压缩包目录字段冲突。") }
                fields[key] = String(line[separator.upperBound...])
            }
            if fields.isEmpty { continue }
            guard let rawPath = fields["Path"] else { throw ArchiveFailure.message("压缩包目录缺少文件路径。") }
            let path = try ArchiveEngine.safeRelativePath(rawPath)
            if path.isEmpty { continue }
            let attributes = fields["Attributes"] ?? ""
            let mode = fields["Mode"] ?? ""
            let unixAttributes = attributes.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            // SLT property names describe the schema, not their value. RAR can
            // report "Alternate Stream = -" and "Links = 1" for normal files.
            // Treating the presence of these keys as a link rejected valid MP3s.
            let linkProperties = ["Symbolic Link", "Hard Link", "Link", "Reparse"]
            let streamProperties = ["Alternate Stream", "Is Alt Stream"]
            let hasLink = linkProperties.contains { isPositive(fields[$0]) }
            let hasStream = streamProperties.contains { isPositive(fields[$0]) }
            guard !hasLink, !hasStream, !mode.hasPrefix("l"),
                  !mode.hasPrefix("b"), !mode.hasPrefix("c"), !mode.hasPrefix("p"),
                  !(unixAttributes.count >= 10 && unixAttributes.first.map { "lbcps".contains($0) } == true) else {
                throw ArchiveFailure.message("压缩包包含链接或特殊文件，已停止：\(path)")
            }
            guard !path.split(separator: "/").contains(where: { $0.contains(":") }) else { throw ArchiveFailure.message("不支持压缩包内的特殊数据流路径。") }
            let canonical = path.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(canonical).inserted else { throw ArchiveFailure.message("压缩包存在重名文件，已停止：\(path)") }
            let directory = fields["Folder"] == "+" || attributes.hasPrefix("D") || attributes.contains(" dr") || mode.hasPrefix("d")
            let size = Int64(fields["Size"] ?? "0") ?? 0
            guard size >= 0 else { throw ArchiveFailure.message("压缩包文件长度异常。") }
            members.append(Member(path: path, size: size, directory: directory, encrypted: fields["Encrypted"] == "+"))
        }
        return Listing(format: format, members: members)
    }

    private static func isPositive(_ value: String?) -> Bool {
        guard let value else { return false }
        return !["", "-", "0", "false", "no"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func preview(source: URL, password: String?, limit: Int, encoding: FilenameEncoding = .automatic, token: CancellationToken = CancellationToken()) throws -> ArchivePreview {
        let listing = try list(source: source, password: password, token: token, encoding: encoding)
        return ArchivePreview(format: listing.format, items: listing.members.prefix(limit).enumerated().map { ArchiveItem(id: $0.offset, path: $0.element.path, size: $0.element.size, isDirectory: $0.element.directory) }, isTruncated: listing.members.count > limit)
    }

    static func extract(source: URL, destinationParent: URL, password: String?, token: CancellationToken,
                        options: ExtractionOptions = ExtractionOptions(), encoding: FilenameEncoding = .automatic,
                        progress: @escaping (ExtractionProgress) -> Void) throws -> ExtractionResult {
        let start = Date()
        let all = try list(source: source, password: password, token: token, encoding: encoding)
        let listing = Listing(format: all.format, members: all.members.filter { options.includes($0.path) })
        if !options.selectedPaths.isEmpty && listing.members.isEmpty { throw ArchiveFailure.message("未找到选中的文件，请重新读取目录。") }
        if password == nil && listing.members.contains(where: \.encrypted) { throw ArchiveFailure.passwordRequired }
        let fm = FileManager.default
        let parent = destinationParent.resolvingSymlinksInPath()
        let capacity = (try? parent.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init) ?? Int64.max
        var size: Int64 = 0
        for member in listing.members {
            let sum = size.addingReportingOverflow(member.size)
            guard !sum.overflow, sum.partialValue <= capacity else { throw ArchiveFailure.message("可用磁盘空间不足。") }
            size = sum.partialValue
        }
        let stage = parent.appendingPathComponent(".quickunzip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let files = listing.members.filter { !$0.directory }.count
        progress(ExtractionProgress(format: listing.format, filename: "正在解压…", fraction: 0, bytesWritten: 0, files: 0))
        // Two decoder threads balance throughput with responsiveness on a MacBook.
        // During thermal pressure, use a single decoder thread for this archive.
        let thermal = ProcessInfo.processInfo.thermalState
        let threads = thermal == .serious || thermal == .critical ? 1 : options.performance.threads
        var includes: [String] = []
        let listFile = parent.appendingPathComponent(".members-\(UUID().uuidString).txt")
        defer { try? fm.removeItem(at: listFile) }
        if !options.selectedPaths.isEmpty || options.ignoreMacMetadata {
            try listing.members.map(\.path).joined(separator: "\n").write(to: listFile, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: listFile.path)
            includes = ["-i@\(listFile.path)", "-scsUTF-8", "-spd"]
        }
        _ = try command(["x", "-y", "-aos", "-mmt=\(threads)", "-bsp1", "-sccUTF-8", "-o\(stage.path)"] + includes + encoding.sevenZipArguments + ["--", source.path], password: password, token: token) { fraction in
            progress(ExtractionProgress(format: listing.format, filename: "7-Zip 正在解压…", fraction: fraction, bytesWritten: Int64(Double(size) * fraction), files: 0))
        }
        try token.check()
        // Validate output before publishing; never follow a decoded link.
        var actualBytes: Int64 = 0
        if let walk = fm.enumerator(at: stage, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]) {
            for case let url as URL in walk {
                try token.check()
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw ArchiveFailure.message("解压结果包含不支持的特殊文件。") }
                if values.isRegularFile == true {
                    actualBytes += Int64(values.fileSize ?? 0)
                    let attrs = try fm.attributesOfItem(atPath: url.path)
                    let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
                    try fm.setAttributes([.posixPermissions: mode & 0o111 != 0 ? 0o755 : 0o644], ofItemAtPath: url.path)
                }
            }
        }
        for member in listing.members {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: stage.appendingPathComponent(member.path).path, isDirectory: &isDir), isDir.boolValue == member.directory else { throw ArchiveFailure.message("压缩包未完整解压：\(member.path)") }
        }
        for index in 0..<10000 {
            let stem = ArchiveEngine.outputName(for: source)
            let name = index == 0 ? stem : "\(stem) (\(index + 1))"
            let destination = parent.appendingPathComponent(name)
            if renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                progress(ExtractionProgress(format: listing.format, filename: "完成", fraction: 1, bytesWritten: actualBytes, files: files))
                return ExtractionResult(destination: destination, format: listing.format, files: files, bytesWritten: actualBytes, duration: Date().timeIntervalSince(start))
            }
            if errno != EEXIST && errno != ENOTEMPTY { throw ArchiveFailure.message("无法保存解压结果：\(String(cString: strerror(errno)))") }
        }
        throw ArchiveFailure.message("同名文件夹过多。")
    }

    static func test(source: URL, password: String?, encoding: FilenameEncoding, token: CancellationToken, progress: @escaping (ExtractionProgress) -> Void) throws -> IntegrityResult {
        let start = Date()
        let listing = try list(source: source, password: password, token: token, encoding: encoding)
        if password == nil && listing.members.contains(where: \.encrypted) { throw ArchiveFailure.passwordRequired }
        let size = listing.members.reduce(Int64(0)) { $0 + $1.size }
        _ = try command(["t", "-mmt=2", "-bsp1"] + encoding.sevenZipArguments + ["--", source.path], password: password, token: token) { fraction in
            progress(ExtractionProgress(format: listing.format, filename: "校验压缩包数据与校验和…", fraction: fraction, bytesWritten: Int64(Double(size) * fraction), files: 0))
        }
        return IntegrityResult(format: listing.format, files: listing.members.filter { !$0.directory }.count, bytesRead: size, duration: Date().timeIntervalSince(start))
    }
}
