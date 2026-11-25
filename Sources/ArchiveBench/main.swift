import Foundation
import ArchiveCore
import Darwin

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: ArchiveBench ARCHIVE OUTPUT_PARENT\n", stderr)
    exit(2)
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let semaphore = DispatchSemaphore(value: 0)
DispatchQueue(label: "app.quickunzip.benchmark", qos: .utility).async {
    do {
        let result = try ArchiveEngine.extract(source: source, destinationParent: output)
        let stats: [String: Any] = ["format": result.format, "bytes": result.bytesWritten, "files": result.files, "seconds": result.duration, "MB_per_second": Double(result.bytesWritten) / result.duration / 1_000_000, "destination": result.destination.path]
        let data = try JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    semaphore.signal()
}
semaphore.wait()
