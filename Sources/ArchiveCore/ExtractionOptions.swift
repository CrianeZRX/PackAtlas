import Foundation

public enum ExtractionLayout: String, CaseIterable, Codable, Sendable {
    case folder = "独立文件夹", smart = "智能解压", here = "解压到当前位置"
}
public enum ConflictPolicy: String, CaseIterable, Codable, Sendable {
    case rename = "自动重命名", ask = "询问", skip = "跳过", replace = "替换"
}
public enum UnicodeNormalization: String, CaseIterable, Codable, Sendable {
    case unchanged = "保持原样", nfc = "NFC", nfd = "NFD"
    func apply(_ value: String) -> String {
        switch self { case .unchanged: return value; case .nfc: return value.precomposedStringWithCanonicalMapping; case .nfd: return value.decomposedStringWithCanonicalMapping }
    }
}
public enum PerformanceMode: String, CaseIterable, Codable, Sendable {
    case balanced = "均衡", foreground = "速度优先", background = "低占用"
    var threads: Int { self == .background ? 1 : self == .foreground ? 4 : 2 }
}

public struct ExtractionOptions: Sendable {
    public var layout: ExtractionLayout = .folder
    public var conflictPolicy: ConflictPolicy = .rename
    public var selectedPaths: Set<String> = []
    public var ignoreMacMetadata = false
    public var normalization: UnicodeNormalization = .unchanged
    public var preserveTimestamps = true
    public var performance: PerformanceMode = .balanced
    public var enableParallelZIP = true
    public init() {}
    func includes(_ path: String) -> Bool {
        if ignoreMacMetadata && path.split(separator: "/").contains(where: { $0 == "__MACOSX" || $0.hasPrefix("._") || $0 == ".DS_Store" }) { return false }
        return selectedPaths.isEmpty || selectedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
    }
}

public struct IntegrityResult: Sendable {
    public let format: String
    public let files: Int
    public let bytesRead: Int64
    public let duration: TimeInterval
    public init(format: String, files: Int, bytesRead: Int64, duration: TimeInterval) { self.format = format; self.files = files; self.bytesRead = bytesRead; self.duration = duration }
}

public enum ArchiveVolumes {
    public static func firstVolume(for source: URL) -> URL {
        let name = source.lastPathComponent
        // A matching serial and segment number distinguish ISZ volumes from ALZ's .iNN names.
        if let match = name.range(of: #"(?i)(\.part\d+\.isz|\.i\d{2})$"#, options: .regularExpression),
           let header = iszHeader(source), header[34] > 0 {
            let suffix = String(name[match])
            let digits = suffix.filter(\.isNumber)
            let partStyle = suffix.lowercased().hasPrefix(".part")
            let expected = Int(header[34]) + (partStyle ? 1 : 0)
            let firstSuffix = partStyle ? ".part" + String(repeating: "0", count: digits.count - 1) + "1.isz" : ".isz"
            let candidate = source.deletingLastPathComponent().appendingPathComponent(String(name[..<match.lowerBound]) + firstSuffix)
            if Int(digits) == expected, let first = iszHeader(candidate), first[34] == 0,
               first[5..<17] == header[5..<17] { return candidate }
            return source
        }
        let patterns = [#"(?i)^(.*\.vol)(\d+)(\.egg)$"#, #"(?i)^(.*\.part)(\d+)(\.rar)$"#, #"(?i)^(.*\.7z\.)(\d{3})$"#, #"(?i)^(.*\.zip\.)(\d{3})$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let p = Range(match.range(at: 1), in: name), let n = Range(match.range(at: 2), in: name) else { continue }
            let suffix = match.numberOfRanges > 3 ? Range(match.range(at: 3), in: name).map { String(name[$0]) } ?? "" : ""
            let digits = String(repeating: "0", count: max(0, name[n].count - 1)) + "1"
            let candidate = source.deletingLastPathComponent().appendingPathComponent(String(name[p]) + digits + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        if source.pathExtension.lowercased().range(of: #"^[a-z]\d{2}$"#, options: .regularExpression) != nil {
            let first = source.deletingPathExtension().appendingPathExtension("alz")
            if FileManager.default.fileExists(atPath: first.path), ArchiveEngine.detectedFormat(source: first) == "ALZ" { return first }
        }
        if source.pathExtension.lowercased().range(of: #"^r\d{2}$"#, options: .regularExpression) != nil {
            let candidate = source.deletingPathExtension().appendingPathExtension("rar")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return source
    }
    private static func iszHeader(_ url: URL) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 48), header.count == 48,
              header.starts(with: "IsZ!".utf8) else { return nil }
        return header
    }

}
