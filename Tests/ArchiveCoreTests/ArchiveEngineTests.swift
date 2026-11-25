import XCTest
import Foundation
@testable import ArchiveCore

final class ArchiveEngineTests: XCTestCase {
    var root: URL!
    var output: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("QuickUnzipTests-\(UUID().uuidString)")
        output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.currentDirectoryURL = root
        let log = Pipe(); p.standardOutput = log; p.standardError = log
        try p.run()
        let data = log.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 { XCTFail(String(decoding: data, as: UTF8.self)) }
        return p.terminationStatus
    }
    func python(_ script: String) throws { try run("/usr/bin/python3", ["-c", script]) }
    func extract(_ name: String, password: String? = nil, token: CancellationToken = CancellationToken(), options: ExtractionOptions = ExtractionOptions(), progress: @escaping (ExtractionProgress) -> Void = { _ in }) throws -> ExtractionResult {
        try ArchiveEngine.extract(source: root.appendingPathComponent(name), destinationParent: output, password: password, token: token, options: options, progress: progress)
    }
    func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func assertNoStaging(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: output.path).contains { $0.hasPrefix(".quickunzip-") }, file: file, line: line)
    }

    func testZIPDetectedByContentWithChineseFilenameAndPreview() throws {
        try python("import zipfile\nwith zipfile.ZipFile('renamed.data','w',compression=zipfile.ZIP_DEFLATED) as z:\n z.writestr('目录/研究.txt','点云感知 ✓')\n z.writestr('empty/',b'')")
        let source = root.appendingPathComponent("renamed.data")
        let preview = try ArchiveEngine.preview(source: source)
        XCTAssertTrue(preview.format.lowercased().contains("zip"))
        XCTAssertEqual(preview.items.count, 2)
        let r = try extract("renamed.data")
        XCTAssertEqual(try contents(r.destination.appendingPathComponent("目录/研究.txt")), "点云感知 ✓")
        XCTAssertEqual(r.files, 1)
        try assertNoStaging()
    }
    func testNeverOverwritesExistingDestination() throws {
        try python("import zipfile\nwith zipfile.ZipFile('a.zip','w') as z: z.writestr('a.txt','hello')")
        let first = try extract("a.zip")
        let second = try extract("a.zip")
        XCTAssertNotEqual(first.destination, second.destination)
        XCTAssertEqual(second.destination.lastPathComponent, "a (2)")
        XCTAssertEqual(try contents(first.destination.appendingPathComponent("a.txt")), "hello")
    }
    func testTARFiltersAndStandaloneGZIP() throws {
        try python("import tarfile,io,gzip,bz2,lzma\nfor mode,ext in [('w:gz','gz'),('w:bz2','bz2'),('w:xz','xz')]:\n with tarfile.open('bundle.tar.'+ext,mode) as t:\n  i=tarfile.TarInfo('a.txt'); i.size=5; t.addfile(i,io.BytesIO(b'hello'))\nfor name,fn in [('single.gz',gzip.compress),('single.bz2',bz2.compress),('single.xz',lzma.compress)]:\n open(name,'wb').write(fn(b'raw text'))")
        for ext in ["gz", "bz2", "xz"] {
            let r = try extract("bundle.tar.\(ext)")
            XCTAssertEqual(try contents(r.destination.appendingPathComponent("a.txt")), "hello")
            XCTAssertFalse(r.destination.lastPathComponent.contains(".tar"))
            let raw = try extract("single.\(ext)")
            XCTAssertEqual(try contents(raw.destination.appendingPathComponent("single")), "raw text")
        }
    }
    func testSevenZipIfAvailable() throws {
        let bin = ["/opt/homebrew/bin/7zz", "/opt/homebrew/bin/7z", "/usr/local/bin/7z"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let bin else { throw XCTSkip("7z fixture generator is optional") }
        try "seven zip".write(to: root.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        try run(bin, ["a", "sample.7z", "sample.txt"])
        let r = try extract("sample.7z")
        XCTAssertEqual(try contents(r.destination.appendingPathComponent("sample.txt")), "seven zip")
        XCTAssertTrue(r.format.lowercased().contains("7-zip"))
    }
    func testZIPPasswordFlow() throws {
        try "secret value".write(to: root.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try run("/usr/bin/zip", ["-q", "-P", "test-only-password", "secret.zip", "secret.txt"])
        XCTAssertThrowsError(try extract("secret.zip")) { error in
            guard case ArchiveFailure.passwordRequired = error else { return XCTFail("Expected passwordRequired, got \(error)") }
        }
        XCTAssertThrowsError(try extract("secret.zip", password: "wrong"))
        let r = try extract("secret.zip", password: "test-only-password")
        XCTAssertEqual(try contents(r.destination.appendingPathComponent("secret.txt")), "secret value")
        try assertNoStaging()
    }
    func testRejectsTraversalAndAbsolutePaths() throws {
        for (index, path) in ["../escape.txt", "/tmp/escape.txt", "C:\\escape.txt", "..\\escape.txt", "ok/../../escape.txt"].enumerated() {
            let escaped = path.debugDescription
            try python("import zipfile\nwith zipfile.ZipFile('bad\(index).zip','w') as z: z.writestr(\(escaped),'bad')")
            XCTAssertThrowsError(try extract("bad\(index).zip"), path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path))
        try assertNoStaging()
    }
    func testRejectsSymbolicAndHardLinks() throws {
        try python("import tarfile\nfor name,kind in [('sym.tar',tarfile.SYMTYPE),('hard.tar',tarfile.LNKTYPE)]:\n with tarfile.open(name,'w') as t:\n  i=tarfile.TarInfo('evil'); i.type=kind; i.linkname='/tmp'; t.addfile(i)")
        XCTAssertThrowsError(try extract("sym.tar"))
        XCTAssertThrowsError(try extract("hard.tar"))
        try assertNoStaging()
    }
    func testRejectsDuplicatesWithoutPartialPublication() throws {
        try python("import zipfile,warnings\nwarnings.simplefilter('ignore')\nwith zipfile.ZipFile('dup.zip','w') as z:\n z.writestr('a.txt','first')\n z.writestr('a.txt','second')")
        XCTAssertThrowsError(try extract("dup.zip"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }
    func testCorruptedCRCLeavesNoOutput() throws {
        try python("import zipfile\nwith zipfile.ZipFile('broken.zip','w') as z: z.writestr('a.txt',b'unique-payload')\np=bytearray(open('broken.zip','rb').read()); i=p.index(b'unique-payload'); p[i]^=1; open('broken.zip','wb').write(p)")
        XCTAssertThrowsError(try extract("broken.zip"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }
    func testCancellationCleansStaging() throws {
        try python("import zipfile\nwith zipfile.ZipFile('large.zip','w') as z: z.writestr('large.bin',b'x'*(8*1024*1024))")
        let token = CancellationToken()
        XCTAssertThrowsError(try extract("large.zip", token: token) { _ in token.cancel() }) { error in
            guard case ArchiveFailure.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }
    func testArbitraryNonArchiveRejected() throws {
        try "ordinary document".write(to: root.appendingPathComponent("fake.zip"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try extract("fake.zip"))
    }
    func testEmptyZIP() throws {
        try python("import zipfile\nzipfile.ZipFile('empty.zip','w').close()")
        let r = try extract("empty.zip")
        XCTAssertEqual(r.files, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.destination.path))
    }
    func testPathAndOutputNames() throws {
        XCTAssertEqual(try ArchiveEngine.safeRelativePath("./foo//bar.txt"), "foo/bar.txt")
        XCTAssertEqual(ArchiveEngine.outputName(for: URL(fileURLWithPath: "/a/test.tar.gz")), "test")
        XCTAssertThrowsError(try ArchiveEngine.safeRelativePath("a/../b"))
    }

    func testEncryptedSevenZipWithWrongExtension() throws {
        guard let bin = SevenZipBackend.executable else { return XCTFail("Bundled 7-Zip missing") }
        try "加密测试".write(to: root.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try run(bin.path, ["a", "-pfixture-password", "-mhe=on", "encrypted.7z", "secret.txt"])
        try FileManager.default.moveItem(at: root.appendingPathComponent("encrypted.7z"), to: root.appendingPathComponent("wrong.zip"))
        XCTAssertEqual(ArchiveEngine.detectedFormat(source: root.appendingPathComponent("wrong.zip")), "7-Zip")
        XCTAssertThrowsError(try extract("wrong.zip")) { error in
            guard case ArchiveFailure.passwordRequired = error else { return XCTFail("Expected password prompt, got \(error)") }
        }
        XCTAssertThrowsError(try extract("wrong.zip", password: "incorrect")) { error in
            guard case ArchiveFailure.wrongPassword = error else { return XCTFail("Expected wrong password, got \(error)") }
        }
        let r = try extract("wrong.zip", password: "fixture-password")
        XCTAssertEqual(try contents(r.destination.appendingPathComponent("secret.txt")), "加密测试")
        try assertNoStaging()
    }

    func testSevenZipRejectsLinks() throws {
        try python("import zipfile,stat\ni=zipfile.ZipInfo('evil'); i.create_system=3; i.external_attr=(stat.S_IFLNK|0o777)<<16\nwith zipfile.ZipFile('links.zip','w') as z: z.writestr(i,'/tmp')")
        XCTAssertThrowsError(try SevenZipBackend.extract(source: root.appendingPathComponent("links.zip"), destinationParent: output, password: nil, token: CancellationToken(), progress: { _ in }))
        try assertNoStaging()
    }

    func testSplitSevenZip() throws {
        guard let bin = SevenZipBackend.executable else { return XCTFail("Bundled 7-Zip missing") }
        try python("import random\nopen('split-data.bin','wb').write(random.Random(42).randbytes(8192))")
        try run(bin.path, ["a", "-mx=0", "-v1k", "split.7z", "split-data.bin"])
        let r = try extract("split.7z.001")
        XCTAssertEqual(try Data(contentsOf: r.destination.appendingPathComponent("split-data.bin")), try Data(contentsOf: root.appendingPathComponent("split-data.bin")))
    }

    func testRARMetadataNegativePropertiesAreNotLinks() throws {
        let listing = "Type = Rar5\n\n----------\nPath = st-12.mp3\nSize = 42\nAttributes = A\nAlternate Stream = -\nLinks = 1\nSymbolic Link = \nHard Link = -\nEncrypted = +\n"
        let result = try SevenZipBackend.parseListing(listing, source: root.appendingPathComponent("wrong.zip"))
        XCTAssertEqual(result.members.count, 1)
        XCTAssertEqual(result.members[0].path, "st-12.mp3")
        for property in ["Alternate Stream = +", "Symbolic Link = /tmp", "Hard Link = a.txt"] {
            let bad = "Type = Rar5\n\n----------\nPath = bad\nSize = 1\n\(property)\n"
            XCTAssertThrowsError(try SevenZipBackend.parseListing(bad, source: root.appendingPathComponent("bad.rar")))
        }
    }

    func testRealRAR5FixtureWithWrongExtension() throws {
        let fixture = Bundle.module.url(forResource: "rar5-stored.rar", withExtension: "uu", subdirectory: "Fixtures")!
        try python("import binascii,pathlib\ns=pathlib.Path(\(fixture.path.debugDescription)).read_text().splitlines()\nopen('rar-renamed.zip','wb').write(b''.join(binascii.a2b_uu(x) for x in s[1:] if x and x!='end'))")
        let r = try extract("rar-renamed.zip")
        XCTAssertTrue(r.format.contains("RAR 5"))
        XCTAssertEqual(r.files, 1)
        let p = try FileManager.default.contentsOfDirectory(at: r.destination, includingPropertiesForKeys: nil).first!
        XCTAssertTrue(try contents(p).contains("libarchive"))
    }

    func testCompressedRAR5WithZIPFilename() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "rar5-compressed.rar", withExtension: "uu", subdirectory: "Fixtures"))
        try python("import binascii,pathlib\nlines=pathlib.Path(\(fixture.path.debugDescription)).read_bytes().splitlines()\npathlib.Path('compressed.zip').write_bytes(b''.join(binascii.a2b_uu(line) for line in lines[1:] if line and line!=b'end'))")
        let result = try extract("compressed.zip")
        XCTAssertEqual(result.files, 1)
        let data = try Data(contentsOf: result.destination.appendingPathComponent("test.bin"))
        XCTAssertEqual(data.count, 1200)
        try python("import pathlib,zlib\nassert zlib.crc32(pathlib.Path(\(result.destination.appendingPathComponent("test.bin").path.debugDescription)).read_bytes()) == 0x7cca70cd")
    }

    func testSmartLayouts() throws {
        try python("import zipfile\nwith zipfile.ZipFile('single.zip','w') as z: z.writestr('a.txt','hello')\nwith zipfile.ZipFile('root.zip','w') as z: z.writestr('project/a.txt','hello')\nwith zipfile.ZipFile('many.zip','w') as z:\n z.writestr('a.txt','a'); z.writestr('b.txt','b')")
        var options = ExtractionOptions(); options.layout = .smart
        let single = try extract("single.zip", options: options)
        XCTAssertEqual(single.destination, output.appendingPathComponent("a.txt"))
        XCTAssertEqual(try contents(single.destination), "hello")
        let folder = try extract("root.zip", options: options)
        XCTAssertEqual(folder.destination.lastPathComponent, "project")
        let many = try extract("many.zip", options: options)
        XCTAssertEqual(many.destination.lastPathComponent, "many")
    }

    func testConflictPoliciesAndPreflight() throws {
        try python("import zipfile\nwith zipfile.ZipFile('a.zip','w') as z:\n z.writestr('a.txt','new'); z.writestr('b.txt','b')")
        let a = output.appendingPathComponent("a.txt")
        try "old".write(to: a, atomically: true, encoding: .utf8)
        var options = ExtractionOptions(); options.layout = .here; options.conflictPolicy = .ask
        XCTAssertThrowsError(try extract("a.zip", options: options)) { error in guard case ArchiveFailure.conflict = error else { return XCTFail("Expected conflict") } }
        XCTAssertEqual(try contents(a), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("b.txt").path))
        options.conflictPolicy = .skip
        let skipped = try extract("a.zip", options: options)
        XCTAssertEqual(skipped.skippedFiles, 1)
        XCTAssertEqual(try contents(a), "old")
        options.conflictPolicy = .rename
        _ = try extract("a.zip", options: options)
        XCTAssertEqual(try contents(output.appendingPathComponent("a (2).txt")), "new")
        options.conflictPolicy = .replace
        _ = try extract("a.zip", options: options)
        XCTAssertEqual(try contents(a), "new")
        try assertNoStaging()
    }

    func testSelectionAndMetadataExclusion() throws {
        try python("import zipfile\nwith zipfile.ZipFile('a.zip','w') as z:\n z.writestr('folder/keep.txt','keep'); z.writestr('folder/other.txt','no'); z.writestr('__MACOSX/._keep.txt','metadata')")
        var options = ExtractionOptions(); options.selectedPaths = ["folder/keep.txt"]
        let r = try extract("a.zip", options: options)
        XCTAssertEqual(try contents(r.destination.appendingPathComponent("folder/keep.txt")), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.destination.appendingPathComponent("folder/other.txt").path))
        options.selectedPaths = []; options.ignoreMacMetadata = true
        let all = try extract("a.zip", options: options)
        XCTAssertFalse(FileManager.default.fileExists(atPath: all.destination.appendingPathComponent("__MACOSX").path))
    }

    func testSevenZipSelectionUsesLiteralNames() throws {
        let bin = SevenZipBackend.executable!
        try "literal".write(to: root.appendingPathComponent("a[1].txt"), atomically: true, encoding: .utf8)
        try "other".write(to: root.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try run(bin.path, ["a", "names.7z", "a[1].txt", "other.txt"])
        var options = ExtractionOptions(); options.selectedPaths = ["a[1].txt"]
        let r = try extract("names.7z", options: options)
        XCTAssertEqual(try contents(r.destination.appendingPathComponent("a[1].txt")), "literal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.destination.appendingPathComponent("other.txt").path))
    }

    func testIntegrityReadsDataAndDoesNotCreateOutput() throws {
        try python("import zipfile\nwith zipfile.ZipFile('a.zip','w') as z: z.writestr('a.txt','payload')")
        let result = try ArchiveEngine.testIntegrity(source: root.appendingPathComponent("a.zip"))
        XCTAssertEqual(result.files, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
        try python("p=bytearray(open('a.zip','rb').read()); p[p.index(b'payload')]^=1; open('a.zip','wb').write(p)")
        XCTAssertThrowsError(try ArchiveEngine.testIntegrity(source: root.appendingPathComponent("a.zip")))
    }

    func testVolumeResolution() throws {
        for name in ["data.part01.rar", "data.part02.rar", "data.7z.001", "data.7z.002"] { try Data().write(to: root.appendingPathComponent(name)) }
        XCTAssertEqual(ArchiveVolumes.firstVolume(for: root.appendingPathComponent("data.part02.rar")).lastPathComponent, "data.part01.rar")
        XCTAssertEqual(ArchiveVolumes.firstVolume(for: root.appendingPathComponent("data.7z.002")).lastPathComponent, "data.7z.001")
    }

    func testCancellationWakesPausedWorker() throws {
        let token = CancellationToken(); token.pause()
        let blocked = expectation(description: "cancel wakes condition")
        DispatchQueue.global().async { do { try token.check(); XCTFail("Should cancel") } catch {} ; blocked.fulfill() }
        token.cancel()
        wait(for: [blocked], timeout: 2)
    }

    func testParallelZIPStoredAndDeflate() throws {
        for method in ["ZIP_STORED", "ZIP_DEFLATED"] {
            try python("import zipfile,random\nr=random.Random(17)\nwith zipfile.ZipFile('parallel-\(method).zip','w',compression=zipfile.\(method)) as z:\n z.writestr('a.bin',r.randbytes(2*1024*1024)); z.writestr('b.bin',r.randbytes(2*1024*1024)); z.writestr('empty.txt',b'')")
            let r = try extract("parallel-\(method).zip")
            XCTAssertTrue(r.format.contains("并行"))
            XCTAssertEqual(r.bytesWritten, 4 * 1024 * 1024)
            try python("import zipfile,pathlib\nz=zipfile.ZipFile('parallel-\(method).zip')\np=pathlib.Path(\(r.destination.path.debugDescription))\nassert all((p/n).read_bytes()==z.read(n) for n in z.namelist())")
        }
    }

    func testParallelZIPCRCFailureCleansAllOutput() throws {
        try python("import zipfile,random\nwith zipfile.ZipFile('bad-parallel.zip','w') as z:\n z.writestr('a.bin',b'known-prefix'+random.Random(1).randbytes(1024*1024)); z.writestr('b.bin',random.Random(2).randbytes(1024*1024))\np=bytearray(open('bad-parallel.zip','rb').read()); p[p.index(b'known-prefix')]^=1; open('bad-parallel.zip','wb').write(p)")
        XCTAssertThrowsError(try extract("bad-parallel.zip"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func testSafeInternalLinksForMacApplicationArchive() throws {
        try python("import tarfile,io\nwith tarfile.open('app.tar','w') as t:\n i=tarfile.TarInfo('App.app/Versions/A/binary'); i.size=7; i.mode=0o755; t.addfile(i,io.BytesIO(b'program'))\n i=tarfile.TarInfo('App.app/Versions/Current'); i.type=tarfile.SYMTYPE; i.linkname='A'; t.addfile(i)\n i=tarfile.TarInfo('App.app/binary'); i.type=tarfile.SYMTYPE; i.linkname='Versions/Current/binary'; t.addfile(i)")
        let r = try extract("app.tar")
        XCTAssertEqual(try contents(r.destination.appendingPathComponent("App.app/binary")), "program")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: r.destination.appendingPathComponent("App.app/Versions/Current").path), "A")
    }

    func testLinkCannotRedirectSubsequentWrites() throws {
        try python("import tarfile,io\nwith tarfile.open('redirect.tar','w') as t:\n i=tarfile.TarInfo('safe/target'); i.size=2; t.addfile(i,io.BytesIO(b'ok'))\n i=tarfile.TarInfo('dir'); i.type=tarfile.SYMTYPE; i.linkname='safe'; t.addfile(i)\n i=tarfile.TarInfo('dir/new.txt'); i.size=4; t.addfile(i,io.BytesIO(b'data'))")
        XCTAssertThrowsError(try extract("redirect.tar"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func testSevenZipIntegrityAndPassword() throws {
        let bin = SevenZipBackend.executable!
        try "secret".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(bin.path, ["a", "-pfixture", "-mhe=on", "secret.7z", "a.txt"])
        XCTAssertThrowsError(try ArchiveEngine.testIntegrity(source: root.appendingPathComponent("secret.7z")))
        let r = try ArchiveEngine.testIntegrity(source: root.appendingPathComponent("secret.7z"), password: "fixture")
        XCTAssertEqual(r.files, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }
}
