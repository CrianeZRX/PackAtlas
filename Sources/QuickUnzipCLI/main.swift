import Foundation
import ArchiveCore
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("--help") {
    print("""
    轻解命令行 / QuickUnzipCLI
    Usage: qunzip [--list [--limit N] | --test] [--smart | --here | --folder] [--out DIR]
                  [--rename | --skip | --replace] [--select PATH] [--password-stdin]
                  [--background | --fast] ARCHIVE
    默认：解压到独立目录，重名自动加序号。支持按内容识别与分卷首卷定位。
    密码通过标准输入读取，不放入命令行参数。
    """)
    exit(0)
}
var options = ExtractionOptions(), source: URL?, output: URL?, password: String?, command = "extract"
var listingLimit = 10_000
var i = 0
while i < arguments.count {
    let arg = arguments[i]
    func next() -> String { i += 1; guard i < arguments.count else { fputs("参数缺少值：\(arg)\n", stderr); exit(2) }; return arguments[i] }
    switch arg {
    case "--list": command = "list"
    case "--limit":
        guard let value = Int(next()), value > 0 else { fputs("--limit 需要正整数。\n", stderr); exit(2) }
        listingLimit = value
    case "--test": command = "test"
    case "--smart": options.layout = .smart
    case "--here": options.layout = .here
    case "--folder": options.layout = .folder
    case "--rename": options.conflictPolicy = .rename
    case "--skip": options.conflictPolicy = .skip
    case "--replace": options.conflictPolicy = .replace
    case "--select": options.selectedPaths.insert(next())
    case "--out": output = URL(fileURLWithPath: next())
    case "--background": options.performance = .background
    case "--fast": options.performance = .foreground
    case "--serial": options.enableParallelZIP = false
    case "--password-stdin": password = readLine()
    default:
        guard !arg.hasPrefix("--"), source == nil else { fputs("未知参数：\(arg)\n", stderr); exit(2) }
        source = URL(fileURLWithPath: arg)
    }
    i += 1
}
guard let source else { fputs("需要压缩包路径。\n", stderr); exit(2) }
_ = pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0)
do {
    let json: Any
    if command == "list" {
        let result = try ArchiveEngine.preview(source: source, limit: listingLimit, password: password)
        json = ["format": result.format, "truncated": result.isTruncated, "items": result.items.map { ["path": $0.path, "size": $0.size, "directory": $0.isDirectory] as [String: Any] }] as [String: Any]
    } else if command == "test" {
        let result = try ArchiveEngine.testIntegrity(source: source, password: password)
        json = ["ok": true, "format": result.format, "files": result.files, "bytes": result.bytesRead, "seconds": result.duration]
    } else {
        let result = try ArchiveEngine.extract(source: source, destinationParent: output ?? source.deletingLastPathComponent(), password: password, options: options)
        json = ["ok": true, "format": result.format, "files": result.files, "bytes": result.bytesWritten, "seconds": result.duration, "outputs": result.outputs.map(\.path), "skipped": result.skippedFiles]
    }
    var object = json as! [String: Any]
    var usage = rusage()
    if getrusage(RUSAGE_SELF, &usage) == 0 { object["peak_resident_bytes"] = usage.ru_maxrss }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
