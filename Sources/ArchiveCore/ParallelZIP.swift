import Foundation
import Darwin
import CZipCodec

// A deliberately narrow fast path: ZIP32, Store/Deflate, ordinary UTF-8 names,
// at least two data members. Unsupported layouts fall back to libarchive.
enum ParallelZIP {
    struct Member {
        let path: String; let packed: UInt64; let size: UInt64; let offset: UInt64
        let crc: UInt32; let method: UInt16; let directory: Bool; let mode: UInt32
        let date: Date?
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock(); let token: CancellationToken; let total: UInt64; let format: String
        let progress: (ExtractionProgress) -> Void
        var values: [String: UInt64] = [:]; var error: Error?; var last = Date.distantPast; var completed = 0
        init(token: CancellationToken, total: UInt64, format: String, progress: @escaping (ExtractionProgress) -> Void) { self.token = token; self.total = total; self.format = format; self.progress = progress }
        func update(_ path: String, bytes: UInt64) -> Bool {
            do { try token.check() } catch { fail(error); return true }
            lock.lock(); defer { lock.unlock() }
            if error != nil { return true }
            values[path] = bytes
            if Date().timeIntervalSince(last) > 0.08 {
                let sum = values.values.reduce(UInt64(0), +)
                progress(ExtractionProgress(format: format, filename: path, fraction: min(0.99, Double(sum) / Double(max(1, total))), bytesWritten: Int64(sum), files: completed))
                last = Date()
            }
            return false
        }
        func fail(_ value: Error) { lock.lock(); if error == nil { error = value }; lock.unlock() }
    }
    private final class Context {
        let state: State; let member: Member; let background: Bool
        init(state: State, member: Member, background: Bool) { self.state = state; self.member = member; self.background = background }
    }

    static func extractIfEligible(source: URL, destinationParent: URL, token: CancellationToken, options: ExtractionOptions,
                                   progress: @escaping (ExtractionProgress) -> Void) throws -> ExtractionResult? {
        guard options.enableParallelZIP, options.performance != .background, let all = try members(source: source), all.filter({ !$0.directory }).count >= 2,
              all.reduce(UInt64(0), { $0 + $1.packed }) >= 1024 * 1024 else { return nil }
        let members = all.filter { options.includes($0.path) }
        guard !members.isEmpty else { throw ArchiveFailure.message("未找到选中的文件。") }
        let start = Date(), fm = FileManager.default
        let total = members.reduce(UInt64(0)) { $0 + $1.size }
        let capacity = (try? destinationParent.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(UInt64.init) ?? UInt64.max
        guard total <= capacity else { throw ArchiveFailure.message("可用磁盘空间不足。") }
        let payload = destinationParent.appendingPathComponent("parallel-zip", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let thermal = ProcessInfo.processInfo.thermalState
        let threads = thermal == .serious || thermal == .critical ? 1 : options.performance.threads
        let format = "ZIP · 并行 \(threads) 线程"
        let state = State(token: token, total: total, format: format, progress: progress)
        for member in members {
            let url = payload.appendingPathComponent(member.path)
            try fm.createDirectory(at: member.directory ? url : url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = threads; queue.qualityOfService = .utility
        for member in members where !member.directory {
            queue.addOperation {
                if state.update(member.path, bytes: 0) { return }
                let input = Darwin.open(source.path, O_RDONLY)
                guard input >= 0 else { state.fail(ArchiveFailure.message("无法读取 ZIP 文件。")); return }
                defer { Darwin.close(input) }
                let url = payload.appendingPathComponent(member.path)
                let output = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard output >= 0 else { state.fail(ArchiveFailure.message("无法创建 \(member.path)：\(String(cString: strerror(errno)))")); return }
                defer { Darwin.close(output) }
                let context = Context(state: state, member: member, background: options.performance == .background)
                let pointer = Unmanaged.passRetained(context).toOpaque()
                defer { Unmanaged<Context>.fromOpaque(pointer).release() }
                let status = qu_zip_extract(input, member.offset, member.packed, member.size, member.crc, Int32(member.method), output, { pointer, bytes in
                    guard let pointer else { return 1 }
                    let c = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
                    switch ProcessInfo.processInfo.thermalState { case .serious: usleep(2_000); case .critical: usleep(10_000); default: break }
                    return c.state.update(c.member.path, bytes: bytes) ? 1 : 0
                }, pointer)
                if status != 0 {
                    state.fail(status == 4 ? ArchiveFailure.cancelled : ArchiveFailure.message("ZIP \(status == 3 ? "CRC 校验失败" : "数据或长度异常")：\(member.path)"))
                    return
                }
                _ = fchmod(output, member.mode & 0o111 == 0 ? 0o644 : 0o755)
                if options.preserveTimestamps, let date = member.date { var times = [timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0), timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)]; _ = futimens(output, &times) }
                state.lock.lock(); state.completed += 1; state.lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        if let error = state.error { throw error }
        try token.check()
        return ExtractionResult(destination: payload, format: format, files: members.filter { !$0.directory }.count, bytesWritten: Int64(total), duration: Date().timeIntervalSince(start))
    }

    static func members(source: URL) throws -> [Member]? {
        let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= 22 else { return nil }
        let tailSize = min(length, 65_557)
        try handle.seek(toOffset: length - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        var end: Int?
        for i in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.u32(i) == 0x06054b50 && i + 22 + Int(tail.u16(i + 20)) == tail.count { end = i; break }
        }
        guard let end, tail.u16(end + 4) == 0, tail.u16(end + 6) == 0, tail.u16(end + 8) == tail.u16(end + 10), tail.u16(end + 10) != 0xffff else { return nil }
        let count = Int(tail.u16(end + 10)), bytes = UInt64(tail.u32(end + 12)), offset = UInt64(tail.u32(end + 16))
        guard count > 0, bytes <= 32 * 1024 * 1024, offset <= length, bytes <= length - offset,
              offset + bytes == length - tailSize + UInt64(end) else { return nil }
        try handle.seek(toOffset: offset)
        let central = try handle.read(upToCount: Int(bytes)) ?? Data()
        var position = 0, result: [Member] = [], seen = Set<String>()
        for _ in 0..<count {
            guard position + 46 <= central.count, central.u32(position) == 0x02014b50 else { return nil }
            let flags = central.u16(position + 8), method = central.u16(position + 10)
            let packed = UInt64(central.u32(position + 20)), size = UInt64(central.u32(position + 24)), local = UInt64(central.u32(position + 42))
            let nameSize = Int(central.u16(position + 28)), extra = Int(central.u16(position + 30)), comment = Int(central.u16(position + 32))
            let attributes = central.u32(position + 38), unixMode = attributes >> 16
            guard flags & 1 == 0, method == 0 || method == 8, packed != UInt32.max, size != UInt32.max,
                  unixMode & UInt32(S_IFMT) == 0 || unixMode & UInt32(S_IFMT) == UInt32(S_IFREG) || unixMode & UInt32(S_IFMT) == UInt32(S_IFDIR),
                  position + 46 + nameSize + extra + comment <= central.count else { return nil }
            guard let rawName = String(data: central.subdata(in: position + 46..<position + 46 + nameSize), encoding: .utf8) else { return nil }
            let name = try ArchiveEngine.safeRelativePath(rawName)
            guard !name.isEmpty, seen.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw ArchiveFailure.message("ZIP 包内有重复文件名：\(name)") }
            guard local + 30 <= offset else { return nil }
            try handle.seek(toOffset: local)
            let header = try handle.read(upToCount: 30) ?? Data()
            guard header.count == 30, header.u32(0) == 0x04034b50, header.u16(8) == method, header.u16(6) == flags else { return nil }
            let dataOffset = local + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
            guard dataOffset <= offset, packed <= offset - dataOffset else { return nil }
            let time = central.u16(position + 12), date = central.u16(position + 14)
            let components = DateComponents(year: 1980 + Int(date >> 9), month: Int((date >> 5) & 15), day: Int(date & 31), hour: Int(time >> 11), minute: Int((time >> 5) & 63), second: Int(time & 31) * 2)
            result.append(Member(path: name, packed: packed, size: size, offset: dataOffset, crc: central.u32(position + 16), method: method, directory: rawName.hasSuffix("/"), mode: unixMode, date: Calendar(identifier: .gregorian).date(from: components)))
            position += 46 + nameSize + extra + comment
        }
        guard position == central.count else { return nil }
        return result
    }
}

private extension Data {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
}
