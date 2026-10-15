import Foundation
import CryptoKit

struct PHPSourceKit: Sendable {
    let directory: URL
    let environment: [String: String]
    let sdkPath: String
}

/// Builds in private storage using Apple's compiler and verified upstream sources.
/// No command in this path discovers, invokes, or installs Homebrew.
enum PHPBuildSupport {
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let hosts: Set<String> = ["www.php.net", "php.net", "downloads.php.net", "museum.php.net",
        "github.com", "api.github.com", "codeload.github.com", "release-assets.githubusercontent.com",
        "objects.githubusercontent.com", "raw.githubusercontent.com", "xdebug.org", "pecl.php.net", "ftp.gnu.org",
        "libzip.org", "ftp.postgresql.org", "download.savannah.gnu.org", "download-mirror.savannah.gnu.org"]

    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && hosts.contains(url.host ?? "")
    }

    static func source(for runtime: RuntimeInstallation, directory: URL, root: URL,
                       progress: @escaping @Sendable (String) async -> Void) async throws -> PHPSourceKit {
        guard runtime.family == .php, runtime.version.range(of: #"^8\.[2-5]\.\d+$"#, options: .regularExpression) != nil else {
            throw GroveError.message("Managed extensions support PHP 8.2–8.5.")
        }
        guard directory.path.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw GroveError.message("PHP's build directory must not contain spaces.")
        }
        let environment = try await compilerEnvironment()
        let actual = try await ProcessRunner.run(executable: runtime.executablePath,
            arguments: ["-n", "-r", "echo PHP_VERSION, '|', (int) PHP_ZTS, '|', (int) PHP_DEBUG, '|', PHP_INT_SIZE;"],
            environment: environment, timeout: 10).requireSuccess()
        guard actual.stdout == "\(runtime.version)|0|0|8", actual.stderr.isEmpty else {
            throw GroveError.message("This installer needs the selected 64-bit, non-thread-safe release of PHP. Refresh PHP versions before trying again.")
        }
        await progress("Downloading PHP \(runtime.version) development sources…")
        struct Release: Decodable {
            struct Source: Decodable { let filename: String; let sha256: String }
            let version: String
            let source: [Source]
        }
        let metadataURL = URL(string: "https://www.php.net/releases/?json&version=\(runtime.version)")!
        let data = try await RuntimeHTTPDownload.data(metadataURL, limit: 1_000_000, acceptsURL: {
            allowed($0) && ["www.php.net", "php.net"].contains($0.host ?? "")
        })
        let metadata = try JSONDecoder().decode(Release.self, from: data)
        let filename = "php-\(runtime.version).tar.xz"
        guard metadata.version == runtime.version, let source = metadata.source.first(where: { $0.filename == filename }) else {
            throw GroveError.message("PHP's official source metadata does not match the selected version.")
        }
        let archive = try await download(url: URL(string: "https://www.php.net/distributions/\(filename)")!,
            sha256: source.sha256, maximumBytes: 40_000_000, root: root)
        try await extract(archive: archive, to: directory)
        let sourceDirectory = directory.appendingPathComponent("php-\(runtime.version)")
        let header = try String(contentsOf: sourceDirectory.appendingPathComponent("main/php_version.h"), encoding: .utf8)
        guard header.contains("#define PHP_VERSION \"\(runtime.version)\""),
              FileManager.default.isExecutableFile(atPath: sourceDirectory.appendingPathComponent("configure").path) else {
            throw GroveError.message("The downloaded PHP source tree is incomplete.")
        }
        return PHPSourceKit(directory: sourceDirectory, environment: environment, sdkPath: environment["SDKROOT"]!)
    }

    static func compilerEnvironment() async throws -> [String: String] {
        let result = try await ProcessRunner.run(executable: "/usr/bin/xcrun", arguments: ["--show-sdk-path"],
            environment: ["PATH": systemPath], timeout: 20)
        let sdk = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, sdk.hasPrefix("/"), FileManager.default.fileExists(atPath: sdk + "/usr/include/stdio.h") else {
            throw GroveError.message("Install Apple's Command Line Tools or Xcode to prepare PHP extensions. Grove does not need Homebrew. Run xcode-select --install in Terminal, then try again.")
        }
        return ["PATH": systemPath, "SDKROOT": sdk, "CC": "/usr/bin/clang", "CXX": "/usr/bin/clang++",
            "CPP": "/usr/bin/clang -E", "CXXCPP": "/usr/bin/clang++ -E", "OBJC": "/usr/bin/clang", "OBJCXX": "/usr/bin/clang++",
            "AR": "/usr/bin/ar", "AS": "/usr/bin/as", "LD": "/usr/bin/ld", "NM": "/usr/bin/nm", "RANLIB": "/usr/bin/ranlib", "STRIP": "/usr/bin/strip",
            "MAKE": "/usr/bin/make", "MAKEFLAGS": "", "MFLAGS": "", "MAKEOVERRIDES": "", "BISON": "/usr/bin/bison", "YACC": "/usr/bin/yacc", "LEX": "/usr/bin/flex",
            "PERL": "/usr/bin/perl", "PYTHON": "/usr/bin/python3", "PYTHON3": "/usr/bin/python3", "SED": "/usr/bin/sed", "AWK": "/usr/bin/awk",
            "GREP": "/usr/bin/grep", "EGREP": "/usr/bin/grep -E", "FGREP": "/usr/bin/grep -F",
            // These names resolve through the controlled PATH, including Grove's
            // private GNU tools once their bootstrap has completed.
            "M4": "m4", "AUTOCONF": "autoconf", "AUTOHEADER": "autoheader", "AUTOM4TE": "autom4te", "PHP_AUTOCONF": "autoconf", "PHP_AUTOHEADER": "autoheader",
            "MACOSX_DEPLOYMENT_TARGET": "14.0", "CFLAGS": "-O2", "CXXFLAGS": "-O2", "CPPFLAGS": "", "LDFLAGS": "", "LIBS": "",
            "CPATH": "", "C_INCLUDE_PATH": "", "CPLUS_INCLUDE_PATH": "", "LIBRARY_PATH": "",
            "PKG_CONFIG": "/usr/bin/false", "PKG_CONFIG_PATH": "", "PKG_CONFIG_LIBDIR": "/var/empty", "PKG_CONFIG_SYSROOT_DIR": "", "CONFIG_SITE": "/dev/null",
            "CMAKE_PREFIX_PATH": "", "CMAKE_TOOLCHAIN_FILE": "", "CMAKE_GENERATOR": "Unix Makefiles",
            "PHPRC": "", "PHP_INI_SCAN_DIR": "", "DYLD_LIBRARY_PATH": "", "DYLD_FALLBACK_LIBRARY_PATH": "", "DYLD_INSERT_LIBRARIES": ""]
    }

    static func download(url: URL, sha256: String, maximumBytes: Int, root: URL) async throws -> URL {
        guard allowed(url), sha256.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else {
            throw GroveError.message("The PHP build package has no trusted download and SHA-256 checksum.")
        }
        let digest = sha256.lowercased()
        let cache = try GrovePaths.ensureDirectory(root.appendingPathComponent("cache/php-build"))
        let destination = cache.appendingPathComponent(digest + ".archive")
        if let values = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
           values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maximumBytes,
           let bytes = try? Data(contentsOf: destination, options: .mappedIfSafe), hash(bytes) == digest {
            return destination
        }
        let bytes = try await RuntimeHTTPDownload.data(url, limit: maximumBytes, acceptsURL: allowed)
        guard hash(bytes) == digest else { throw GroveError.message("A PHP build package failed its SHA-256 check. Nothing from that package was executed.") }
        try Task.checkCancellation()
        try bytes.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func extract(archive: URL, to directory: URL, maximumBytes: Int = 512_000_000) async throws {
        let limit = 16_000_000
        let names = try await ProcessRunner.run(executable: "/usr/bin/tar", arguments: ["-tf", archive.path],
            environment: ["LC_ALL": "en_US.UTF-8", "PATH": systemPath], timeout: 90, outputLimit: limit).requireSuccess().stdout
        let listing = try await ProcessRunner.run(executable: "/usr/bin/tar", arguments: ["-tvf", archive.path],
            environment: ["LC_ALL": "en_US.UTF-8", "PATH": systemPath], timeout: 90, outputLimit: limit).requireSuccess().stdout
        guard names.utf8.count < limit, listing.utf8.count < limit else { throw GroveError.message("The PHP source archive has too many entries.") }
        try validateArchive(names: names, listing: listing, maximumBytes: maximumBytes)
        _ = try GrovePaths.ensureDirectory(directory)
        let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw GroveError.message("The PHP build folder was replaced by a symbolic link.") }
        for name in names.split(separator: "\n") {
            var destination = directory
            for component in name.split(separator: "/") where component != "." {
                destination.appendPathComponent(String(component))
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                    throw GroveError.message("The archive would overwrite or traverse an existing symbolic link.")
                }
            }
        }
        _ = try await ProcessRunner.run(executable: "/usr/bin/tar",
            arguments: ["-xf", archive.path, "-C", directory.path, "--no-same-owner", "--no-same-permissions", "--no-acls", "--no-xattrs"],
            environment: ["PATH": systemPath], timeout: 120).requireSuccess()
    }

    static func validateArchive(names: String, listing: String, maximumBytes: Int) throws {
        let entries = names.split(separator: "\n", omittingEmptySubsequences: true)
        let details = listing.split(separator: "\n", omittingEmptySubsequences: true)
        guard !entries.isEmpty, entries.count < 100_000, entries.count == details.count,
              entries.allSatisfy({ path in
                  !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\r")
                      && !path.split(separator: "/").contains("..")
              }) else { throw GroveError.message("The PHP source archive contains unsafe paths.") }
        var total = 0
        var links: [String: String] = [:]
        var paths = Set<String>()
        for (name, entry) in zip(entries, details) {
            let path = name.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
            guard !path.isEmpty, paths.insert(path).inserted else { throw GroveError.message("The PHP source archive contains duplicate paths.") }
            let fields = entry.split(whereSeparator: \.isWhitespace)
            guard let kind = entry.first, ["-", "d", "l"].contains(kind), fields.count >= 9,
                  let size = Int(fields[4]), size >= 0, size <= maximumBytes - total else {
                throw GroveError.message("The PHP source archive contains a hard link, special file, or excessive expanded data.")
            }
            total += size
            if kind == "l" {
                guard let separator = entry.range(of: " -> ", options: .backwards) else { throw GroveError.message("An archive link is malformed.") }
                let target = String(entry[separator.upperBound...])
                guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"), !target.contains("\r") else {
                    throw GroveError.message("An archive link points outside its private build directory.")
                }
                links[path] = target
            }
        }
        // Never extract a member through an archive-created symlink, regardless
        // of member order. Relative aliases themselves are common in SDKs.
        for path in paths {
            let pieces = path.split(separator: "/")
            for length in 1..<pieces.count where links[pieces.prefix(length).joined(separator: "/")] != nil {
                throw GroveError.message("The archive writes files through a symbolic link.")
            }
        }
        for (path, target) in links {
            var budget = 64
            _ = try resolveArchiveLink(path: path, target: target, links: links, budget: &budget)
        }
    }

    private static func resolveArchiveLink(path: String, target: String, links: [String: String], budget: inout Int) throws -> [String] {
        budget -= 1
        guard budget >= 0 else { throw GroveError.message("The archive contains a cyclic symbolic link.") }
        var stack = path.split(separator: "/").dropLast().map(String.init)
        for piece in target.split(separator: "/").map(String.init) {
            if piece == "." { continue }
            if piece == ".." {
                guard !stack.isEmpty else { throw GroveError.message("An archive link escapes its private build directory.") }
                stack.removeLast()
            } else {
                stack.append(piece)
                let name = stack.joined(separator: "/")
                if let next = links[name] { stack = try resolveArchiveLink(path: name, target: next, links: links, budget: &budget) }
            }
        }
        return stack
    }
}
