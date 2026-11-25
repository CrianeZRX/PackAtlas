import Foundation
import Darwin

enum LegacyArchive {
    static func format(_ data: Data, extension ext: String) -> String? {
        let p = [UInt8](data)
        if p.starts(with: [0x41,0x4c,0x5a,1]) { return "ALZ" }
        if p.starts(with: Array("EGGA".utf8)) { return "EGG" }
        if p.starts(with: Array("IsZ!".utf8)) { return "ISZ" }
        if p.count > 6, p.starts(with: Array("AES".utf8)), p[3] <= 3 { return "AES Crypt" }
        if p.count >= 14, p[7..<14].elementsEqual("**ACE**".utf8) { return "ACE" }
        if p.count >= 7, ["-pm0-", "-pm1-", "-pm2-"].contains(String(decoding: p[2..<7], as: UTF8.self)) { return "PMarc" }
        if p.starts(with: [0x37,0x6b,0x53,0x74,0xa0,0x31,0x83,0xd3,0x8c,0xb2,0x28,0xb0,0xd3]) || p.starts(with: Array("zPQ".utf8)) { return "ZPAQ" }
        if p.starts(with: Array("begin ".utf8)) { return ext == "xxe" ? "XXencode" : "UUencode" }
        if ["bvx1","bvx2","bvxn","bvx-"].contains(String(decoding: p.prefix(4), as: UTF8.self)) { return "LZFSE" }
        if p.starts(with: [0x42,0x48,5,7]) { return "BlakHole" }
        return nil
    }

    static let formats: Set<String> = ["ALZ","EGG","ACE","PMarc","ZPAQ","Brotli","ISZ","LZFSE","XXencode","UUencode","AES Crypt","BlakHole"]

    struct Entry: Decodable { let path: String; let size: Int64; let directory: Bool }
    struct Reply: Decodable { let items: [Entry]; let files: Int; let size: Int64; let truncated: Bool }

    static func run(_ mode: String, format: String, source: URL, destination: URL? = nil,
                    password: String?, encoding: FilenameEncoding, token: CancellationToken, options: ExtractionOptions = ExtractionOptions(), limit: Int = 10000) throws -> Reply {
        let fm = FileManager.default
        let roots = [Bundle.main.resourceURL?.appendingPathComponent("Rare"),
                     Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Rare"),
                     URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/rare")]
        guard let root = roots.compactMap({ $0 }).first(where: { fm.isExecutableFile(atPath: $0.appendingPathComponent("runtime/bin/python").path) }) else {
            throw ArchiveFailure.message("缺少旧格式解码组件，请重新安装轻解。")
        }
        let scratch = (destination?.deletingLastPathComponent() ?? fm.temporaryDirectory).appendingPathComponent(".quickunzip-reader-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let out = scratch.appendingPathComponent("result"), err = scratch.appendingPathComponent("diagnostic")
        guard fm.createFile(atPath: out.path, contents: nil), fm.createFile(atPath: err.path, contents: nil) else { throw ArchiveFailure.message("无法创建解码工作文件。") }
        let output = try FileHandle(forWritingTo: out), diagnostic = try FileHandle(forWritingTo: err)
        defer { try? output.close(); try? diagnostic.close() }
        var request: [String: Any] = ["source": source.path, "format": format, "mode": mode, "limit": max(0,limit), "scratch": scratch.path, "outputName": ArchiveEngine.outputName(for: source), "selected": Array(options.selectedPaths), "ignoreMac": options.ignoreMacMetadata]
        request["folder"] = destination?.path
        request["password"] = password
        let codecs: [FilenameEncoding: String] = [.utf8:"utf8",.gb18030:"gb18030",.big5:"big5",.japanese:"cp932",.korean:"cp949"]
        request["encoding"] = codecs[encoding]
        let inputData = try JSONSerialization.data(withJSONObject: request)
        let p = Process(), input = Pipe()
        p.executableURL = root.appendingPathComponent("runtime/bin/python")
        p.arguments = ["-I","-S","-B",root.appendingPathComponent("rare.py").path]
        p.currentDirectoryURL = scratch
        p.qualityOfService = .utility
        p.standardOutput = output; p.standardError = diagnostic; p.standardInput = input
        try token.check()
        try p.run()
        let pid = p.processIdentifier
        // Workers and their children share a private process group.
        func signalWorker(_ sig: Int32) {
            if getpgid(pid) == pid { _ = kill(-pid,sig) } else { _ = kill(pid,sig) }
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: inputData)
            try input.fileHandleForWriting.close()
            while p.isRunning {
                if token.isPaused {
                    signalWorker(SIGSTOP)
                    try token.check()
                    signalWorker(SIGCONT)
                }
                try token.check()
                Thread.sleep(forTimeInterval: 0.035)
            }
            try token.check()
        } catch {
            try? input.fileHandleForWriting.close()
            if p.isRunning { signalWorker(SIGKILL) }
            p.waitUntilExit()
            throw error
        }
        p.waitUntilExit()
        if p.terminationStatus == 41 { throw ArchiveFailure.passwordRequired }
        if p.terminationStatus == 42 { throw ArchiveFailure.wrongPassword }
        if p.terminationStatus != 0 {
            let h = try FileHandle(forReadingFrom: err); defer { try? h.close() }
            let detail = String(decoding: try h.read(upToCount: 2048) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveFailure.message("\(format) 解码失败。\(detail)")
        }
        return try JSONDecoder().decode(Reply.self, from: Data(contentsOf: out))
    }
}
