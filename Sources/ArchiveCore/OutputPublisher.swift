import Foundation
import Darwin

enum OutputPublisher {
    struct Result { let destination: URL; let outputs: [URL]; let skipped: Int }
    private struct Move { let from: URL; let to: URL }

    static func publish(payload: URL, parent: URL, archiveName: String, options: ExtractionOptions,
                        token: CancellationToken, workspace: URL) throws -> Result {
        let fm = FileManager.default
        try normalize(in: payload, form: options.normalization)
        let roots = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let separate = options.layout == .folder || (options.layout == .smart && roots.count != 1)
        let pairs: [(URL, URL)] = separate ? [(payload, parent.appendingPathComponent(archiveName))] : roots.map { ($0, parent.appendingPathComponent($0.lastPathComponent)) }
        var conflicts: [String] = []
        func collect(_ source: URL, _ target: URL, merge: Bool) throws {
            if !exists(target) { return }
            if merge && directory(source) && directory(target) {
                for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) { try collect(child, target.appendingPathComponent(child.lastPathComponent), merge: true) }
            } else { conflicts.append(target.lastPathComponent) }
        }
        if options.conflictPolicy == .ask {
            for (source, target) in pairs { try collect(source, target, merge: !separate) }
            if !conflicts.isEmpty { throw ArchiveFailure.conflict(conflicts) }
        }
        let backup = workspace.appendingPathComponent("originals", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        var moves: [Move] = [], backups: [Move] = [], outputs: [URL] = [], skipped = 0
        func moveExclusive(_ source: URL, _ target: URL) throws {
            guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw ArchiveFailure.message("无法保存 \(target.lastPathComponent)：\(String(cString: strerror(errno)))") }
            moves.append(Move(from: source, to: target))
        }
        func commit(_ source: URL, _ proposed: URL, merge: Bool) throws -> URL? {
            try token.check()
            if exists(proposed) && merge && directory(source) && directory(proposed) {
                for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) { _ = try commit(child, proposed.appendingPathComponent(child.lastPathComponent), merge: true) }
                return proposed
            }
            var target = proposed
            if exists(target) {
                switch options.conflictPolicy {
                case .ask: throw ArchiveFailure.conflict([target.lastPathComponent])
                case .skip: skipped += 1; return nil
                case .rename: target = unique(proposed)
                case .replace:
                    let saved = backup.appendingPathComponent(UUID().uuidString)
                    try fm.moveItem(at: target, to: saved)
                    backups.append(Move(from: saved, to: target))
                }
            }
            try moveExclusive(source, target)
            return target
        }
        do {
            for (source, target) in pairs { if let output = try commit(source, target, merge: !separate) { outputs.append(output) } }
        } catch {
            var rollbackFailed = false
            for item in moves.reversed() { do { try fm.moveItem(at: item.to, to: item.from) } catch { rollbackFailed = true } }
            for item in backups.reversed() { do { try fm.moveItem(at: item.from, to: item.to) } catch { rollbackFailed = true } }
            if rollbackFailed {
                try? Data().write(to: workspace.appendingPathComponent(".preserve-backup"))
                throw ArchiveFailure.message("保存失败，部分文件未能回滚。备份保留在：\(workspace.path)")
            }
            throw error
        }
        return Result(destination: outputs.count == 1 ? outputs[0] : parent, outputs: outputs, skipped: skipped)
    }

    static func exists(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }
    private static func directory(_ url: URL) -> Bool {
        var value = stat(); return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR
    }
    private static func unique(_ url: URL) -> URL {
        let isDir = directory(url)
        let ext = isDir ? "" : url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        for index in 2...10000 {
            let suffix = ext.isEmpty ? "" : "." + ext
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(index))\(suffix)")
            if !exists(candidate) { return candidate }
        }
        return url.deletingLastPathComponent().appendingPathComponent("\(base)-\(UUID().uuidString)")
    }
    private static func normalize(in directory: URL, form: UnicodeNormalization) throws {
        if form == .unchanged { return }
        let fm = FileManager.default
        for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if self.directory(child) { try normalize(in: child, form: form) }
            let name = form.apply(child.lastPathComponent)
            if name.utf8.elementsEqual(child.lastPathComponent.utf8) { continue }
            let target = child.deletingLastPathComponent().appendingPathComponent(name)
            // Case/normalization-insensitive volumes may refer to the same inode.
            var a = stat(), b = stat()
            if lstat(child.path, &a) == 0 && lstat(target.path, &b) == 0 && a.st_ino != b.st_ino { throw ArchiveFailure.message("Unicode 规范化后文件名冲突：\(name)") }
            if rename(child.path, target.path) != 0 { throw ArchiveFailure.message("无法规范化文件名：\(name)") }
        }
    }
}
