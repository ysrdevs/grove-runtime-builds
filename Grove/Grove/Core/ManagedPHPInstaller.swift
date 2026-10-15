import Foundation
import CryptoKit

enum ManagedPHPInstaller {
    struct Receipt: Codable {
        let provider: String
        let version: String
        let architecture: String
        let installedAt: Date
        let archivesSHA256: [String: String]
        let source: URL
    }
    static let requiredModules: Set<String> = ["bcmath", "ctype", "curl", "dom", "fileinfo", "filter", "hash", "mbstring", "openssl", "pdo", "pdo_mysql", "pdo_sqlite", "phar", "session", "tokenizer", "xml", "xmlreader", "xmlwriter", "zip"]

    /// Release builders use the upstream standalone baseline. The application
    /// installs only Grove's signed, complete prebuilt packages above.
    static func installStaticPHP(_ package: ManagedPHPCatalog.Package, root: URL,
                        progress: @escaping @Sendable (String) async -> Void) async throws -> RuntimeInstallation {
        guard package.architecture == ManagedPHPCatalog.architecture,
              ManagedPHPCatalog.validIdentifier(package.identifier, version: package.version) else { throw GroveError.message("Unsupported PHP package.") }
        let parent = try GrovePaths.ensureDirectory(root.appendingPathComponent("runtimes/php", isDirectory: true))
        let destination = parent.appendingPathComponent(package.version, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw GroveError.message("PHP \(package.version) is already in Grove’s downloads. Refresh the installed list before continuing.")
        }
        let stage = parent.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let bin = try GrovePaths.ensureDirectory(stage.appendingPathComponent("bin", isDirectory: true))
        var digests = [String: String]()
        for sapi in ["cli", "fpm"] {
            try Task.checkCancellation()
            await progress("Downloading PHP \(package.version)\(sapi == "fpm" ? "-FPM" : "")…")
            let bytes = try await ManagedPHPDownload.data(package.url(sapi: sapi), limit: 128_000_000)
            let archive = stage.appendingPathComponent("\(sapi).tar.gz")
            try bytes.write(to: archive, options: .atomic)
            digests[package.archiveName(sapi: sapi)] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let executable = sapi == "cli" ? "php" : "php-fpm"
            await progress("Checking PHP \(package.version)\(sapi == "fpm" ? "-FPM" : "")…")
            try await extract(archive: archive, executable: executable, directory: bin)
            try validateMachO(at: bin.appendingPathComponent(executable), architecture: package.architecture)
            try FileManager.default.removeItem(at: archive)
        }
        try Task.checkCancellation()
        await progress("Verifying PHP and PHP-FPM…")
        try await verifyBinaries(directory: bin, expectedVersion: package.version)
        let receipt = Receipt(provider: "StaticPHP", version: package.version, architecture: package.architecture,
                              installedAt: Date(), archivesSHA256: digests, source: ManagedPHPCatalog.baseURL)
        try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent("grove-runtime.json"), options: .atomic)
        try "PHP runtime supplied by StaticPHP (https://static-php.dev).\nSource: https://github.com/crazywhalecc/static-php-cli\nPHP license: https://www.php.net/license/\nBundled library notices: https://dl.static-php.dev/v3/php-bin/common/license/\n".write(to: stage.appendingPathComponent("SOURCE.txt"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        // Commit only a complete, native, working CLI/FPM pair. Old versions are
        // never replaced, including files used by running or exactly pinned sites.
        try FileManager.default.moveItem(at: stage, to: destination)
        return .init(family: .php, version: package.version, executablePath: destination.appendingPathComponent("bin/php").path, source: "Grove")
    }

    static func validateArchive(names: String, details: String, executable: String) throws {
        let names = names.split(separator: "\n").map(String.init)
        let entries = details.split(separator: "\n").map(String.init)
        guard names == [executable], entries.count == 1 else { throw GroveError.message("The PHP archive contains unexpected files. Nothing was installed.") }
        let regex = try NSRegularExpression(pattern: #"^-[rwxstST-]{9}\s+\S+\s+\S+\s+\S+\s+(\d+)\s"#)
        guard let match = regex.firstMatch(in: entries[0], range: NSRange(entries[0].startIndex..., in: entries[0])),
              let range = Range(match.range(at: 1), in: entries[0]), let size = Int(entries[0][range]),
              (1...256_000_000).contains(size) else { throw GroveError.message("The PHP archive must contain one bounded regular executable.") }
    }
    private static func extract(archive: URL, executable: String, directory: URL) async throws {
        let names = try await ProcessRunner.run(executable: "/usr/bin/tar", arguments: ["-tzf", archive.path], timeout: 30).requireSuccess().stdout
        let details = try await ProcessRunner.run(executable: "/usr/bin/tar", arguments: ["-tvzf", archive.path], timeout: 30).requireSuccess().stdout
        try validateArchive(names: names, details: details, executable: executable)
        try Task.checkCancellation()
        try await ProcessRunner.run(executable: "/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", directory.path, "--no-same-owner", "--", executable], timeout: 60).requireSuccess()
        let binary = directory.appendingPathComponent(executable)
        let values = try binary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 256_000_000 else { throw GroveError.message("The PHP executable could not be validated.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    /// Read Mach-O load commands directly: this check works on a Mac without
    /// Xcode, Homebrew or command-line developer tools installed.
    static func validateMachO(at url: URL, architecture: String, isExtension: Bool = false) throws {
        try validateMachO(data: Data(contentsOf: url, options: .mappedIfSafe), architecture: architecture, isExtension: isExtension)
    }
    static func validateMachO(data: Data, architecture: String, isExtension: Bool = false) throws {
        func invalid() -> GroveError { .message("This PHP download is not a standalone native executable for this Mac.") }
        func word(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw invalid() }
            return (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << ($1 * 8)) }
        }
        guard ["aarch64", "x86_64"].contains(architecture), data.count >= 32, try word(0) == 0xfeedfacf,
              try word(4) == (architecture == "aarch64" ? 0x0100000c : 0x01000007), try word(12) == (isExtension ? 8 : 2) else { throw invalid() }
        let count = Int(try word(16)), bytes = Int(try word(20))
        guard count > 0, count <= 4096, bytes <= 1_048_576, 32 + bytes <= data.count else { throw invalid() }
        var offset = 32
        for _ in 0..<count {
            let command = try word(offset), size = Int(try word(offset + 4))
            guard size >= 8, offset + size <= 32 + bytes else { throw invalid() }
            if [UInt32(0xc), 0x80000018, 0x8000001f, 0x80000023, 0x20].contains(command) {
                guard size >= 24 else { throw invalid() }
                let nameOffset = Int(try word(offset + 8))
                guard nameOffset >= 24, nameOffset < size else { throw invalid() }
                let raw = data[(offset + nameOffset)..<(offset + size)]
                guard let end = raw.firstIndex(of: 0), let path = String(data: raw.prefix(upTo: end), encoding: .utf8),
                      !path.split(separator: "/").contains(".."), path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/Library/") else { throw invalid() }
            }
            offset += size
        }
        guard offset == 32 + bytes else { throw invalid() }
    }
    static func verifyBinaries(directory: URL, expectedVersion: String) async throws {
        struct Probe: Decodable { let version: String; let sapi: String; let modules: [String] }
        let result = try await ProcessRunner.run(executable: directory.appendingPathComponent("php").path,
            arguments: ["-n", "-r", "echo json_encode(['version'=>PHP_VERSION,'sapi'=>PHP_SAPI,'modules'=>get_loaded_extensions()]);"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], removingEnvironment: ["PHPRC", "PHP_INI_SCAN_DIR", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES"], timeout: 15).requireSuccess()
        let probe = try JSONDecoder().decode(Probe.self, from: Data(result.stdout.utf8))
        guard probe.version == expectedVersion, probe.sapi == "cli", requiredModules.isSubset(of: Set(probe.modules.map { $0.lowercased() })) else {
            throw GroveError.message("PHP did not report the requested version and required extensions. The download was discarded.")
        }
        let fpm = try await ProcessRunner.run(executable: directory.appendingPathComponent("php-fpm").path,
            arguments: ["-n", "-v"], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            removingEnvironment: ["PHPRC", "PHP_INI_SCAN_DIR", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES"], timeout: 15).requireSuccess()
        guard fpm.stdout.hasPrefix("PHP \(expectedVersion) (fpm-fcgi)") else { throw GroveError.message("PHP-FPM does not match the requested PHP version. The download was discarded.") }
    }
}
