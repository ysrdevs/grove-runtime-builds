import XCTest
@testable import GroveCore

final class ManagedPHPDependencyTests: XCTestCase {
    func testPrepareParityLibrariesFromExistingPrivatePrefix() async throws {
        let process = ProcessInfo.processInfo.environment
        guard let fixture = process["GROVE_PHP_PARITY_LIBRARY_FIXTURE"], let location = process["GROVE_PHP_PARITY_TEST_WORKSPACE"] else {
            throw XCTSkip("Opt-in: build extra static PHP dependencies in an isolated copy of an existing private release prefix.")
        }
        let workspace = URL(fileURLWithPath: location)
        guard workspace.path.hasPrefix("/private/tmp/GrovePHPParity"), !FileManager.default.fileExists(atPath: workspace.path) else {
            throw GroveError.message("Choose a new GrovePHPParity workspace under /private/tmp.")
        }
        _ = try GrovePaths.ensureDirectory(workspace)
        let prefix = workspace.appendingPathComponent("prefix")
        try FileManager.default.copyItem(atPath: fixture, toPath: prefix.path)
        if let entries = FileManager.default.enumerator(at: prefix, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for file in entries.allObjects.compactMap({ $0 as? URL }) where ["pc", "la"].contains(file.pathExtension) || file.lastPathComponent == "pkg-config" {
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if attributes.isRegularFile == true, attributes.isSymbolicLink != true {
                    let text = try String(contentsOf: file, encoding: .utf8)
                    try text.replacingOccurrences(of: fixture, with: prefix.path).write(to: file, atomically: true, encoding: .utf8)
                }
            }
        }
        var environment = try await PHPBuildSupport.compilerEnvironment()
        environment["PKG_CONFIG"] = prefix.appendingPathComponent("bin/pkg-config").path
        environment["PKG_CONFIG_LIBDIR"] = prefix.appendingPathComponent("lib/pkgconfig").path
        environment["CPPFLAGS"] = "-I\(prefix.path)/include"
        environment["LDFLAGS"] = "-L\(prefix.path)/lib"
        var sources: [String: URL] = [:]
        for package in ManagedPHPParityDependencies.sources {
            let archive = try await PHPBuildSupport.download(url: URL(string: package.url)!, sha256: package.digest, maximumBytes: package.maximumBytes, root: workspace)
            let destination = workspace.appendingPathComponent("source-" + package.name)
            try await PHPBuildSupport.extract(archive: archive, to: destination)
            sources[package.name] = destination.appendingPathComponent(package.topDirectory)
            try ManagedPHPParityDependencies.preserveSourceArchive(package, archive: archive, prefix: prefix)
        }
        try await ManagedPHPParityDependencies.prepare(sources: sources, prefix: prefix, directory: workspace, environment: environment, progress: { print($0) })
        for name in ["libintl.a", "libldap.a", "liblber.a", "libc-client.a", "libMagickWand-7.Q16HDRI.a", "libMagickCore-7.Q16HDRI.a", "libodbc.a", "libodbcinst.a"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("lib/" + name).path), name)
        }
        print("Parity libraries prepared at \(prefix.path)")
    }

    func testPinnedPackagesCoverBothNativeArchitecturesAndExplicitSources() throws {
        XCTAssertEqual(Set(ManagedPHPDependencyBuilder.hostedPackages.map { $0.0 }).count, ManagedPHPDependencyBuilder.hostedPackages.count)
        for (_, arm, intel) in ManagedPHPDependencyBuilder.hostedPackages {
            for digest in [arm, intel] { XCTAssertNotNil(digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression)) }
            XCTAssertNotEqual(arm, intel)
        }
        for package in ManagedPHPDependencyBuilder.sourcePackages {
            XCTAssertNotNil(package.digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression))
            XCTAssertEqual(URL(string: package.url)?.scheme, "https")
            XCTAssertFalse(package.url.contains("latest"))
            XCTAssertFalse(package.topDirectory.contains(".."))
        }
    }

    func testRelocationOnlyChangesBuildMetadata() throws {
        let prefix = try GrovePaths.ensureDirectory(FileManager.default.temporaryDirectory.appendingPathComponent("GroveLibraries-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: prefix) }
        let metadata = prefix.appendingPathComponent("test.pc")
        let library = prefix.appendingPathComponent("test.a")
        let bytes = Data("@build_root_path@ @build_lib_path@".utf8)
        try bytes.write(to: metadata); try bytes.write(to: library)
        try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("alias.pc"), withDestinationURL: metadata)
        try ManagedPHPExtensionInstaller.relocateMetadata(in: prefix)
        XCTAssertEqual(try String(contentsOf: metadata, encoding: .utf8), prefix.path + " " + prefix.appendingPathComponent("lib").path)
        XCTAssertEqual(try Data(contentsOf: library), bytes)
    }

    func testBuiltModulesRejectDependenciesOutsideMacOS() throws {
        XCTAssertNoThrow(try ManagedPHPExtensionInstaller.validateDependencies("intl.so:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n\t/usr/lib/libc++.1.dylib (compatibility version 1.0.0, current version 1.0.0)\n"))
        for dependency in ["/opt/homebrew/lib/libicu.dylib", "/private/tmp/build/libicu.dylib", "@rpath/libicu.dylib", "/usr/lib/../../tmp/injected.dylib"] {
            XCTAssertThrowsError(try ManagedPHPExtensionInstaller.validateDependencies("intl.so:\n\t\(dependency) (compatibility version 1.0.0, current version 1.0.0)\n"))
        }
    }

    func testPinnedCurlSourceArchivesPassExtractionPolicy() async throws {
        guard let path = ProcessInfo.processInfo.environment["GROVE_PHP_CURL_SOURCE_FIXTURES"] else {
            throw XCTSkip("Opt-in: validates previously downloaded pinned curl dependency archives.")
        }
        let names: Set<String> = ["curl", "nghttp2", "nghttp3", "ngtcp2", "unistring", "idn"]
        for package in ManagedPHPDependencyBuilder.sourcePackages where names.contains(package.name) {
            let archive = URL(fileURLWithPath: path).appendingPathComponent(package.name + ".archive")
            let bytes = try Data(contentsOf: archive)
            XCTAssertLessThanOrEqual(bytes.count, package.maximumBytes, package.name)
            XCTAssertEqual(PHPBuildSupport.hash(bytes), package.digest, package.name)
            let names = try await ProcessRunner.run(executable: "/usr/bin/tar", arguments: ["-tf", archive.path], timeout: 30, outputLimit: 16_000_000).requireSuccess().stdout
            let listing = try await ProcessRunner.run(executable: "/usr/bin/tar", arguments: ["-tvf", archive.path], timeout: 30, outputLimit: 16_000_000).requireSuccess().stdout
            XCTAssertNoThrow(try PHPBuildSupport.validateArchive(names: names, listing: listing, maximumBytes: 512_000_000), package.name)
        }
    }

    func testPreparePrivateLibrariesAndUseNativeAPIs() async throws {
        guard ProcessInfo.processInfo.environment["GROVE_PHP_DEPENDENCY_TESTS"] == "1" else { throw XCTSkip("Opt-in: downloads and builds pinned PHP dependency sources with Apple's tools.") }
        // Intentionally use macOS's /tmp alias while Process.currentDirectoryURL
        // may resolve it to /private/tmp, reproducing the app's GNUmakefile bug.
        let workspace = try GrovePaths.ensureDirectory(URL(fileURLWithPath: "/tmp/GroveDependencyTest-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: workspace) }
        if let fixture = ProcessInfo.processInfo.environment["GROVE_PHP_DEPENDENCY_CACHE_FIXTURE"] {
            let cache = try GrovePaths.ensureDirectory(workspace.appendingPathComponent("root/cache"))
            try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: cache.appendingPathComponent("php-build"))
        }
        let prepared = try await ManagedPHPExtensionInstaller.prepareLibraries(directory: workspace.appendingPathComponent("build"), root: workspace.appendingPathComponent("root"), progress: { print($0) })
        let source = workspace.appendingPathComponent("probe.cpp"), binary = workspace.appendingPathComponent("probe")
        try Data("""
        #include <stdio.h>
        #include <unicode/unorm2.h>
        #include <sodium.h>
        #include <libpq-fe.h>
        #include <zip.h>
        #include <avif/avif.h>
        #include <curl/curl.h>
        #include <string.h>
        #include <ft2build.h>
        #include FT_FREETYPE_H
        int main() {
            UErrorCode e=U_ZERO_ERROR;
            const UNormalizer2 *normalizer=unorm2_getNFCInstance(&e);
            FT_Library ft;
            if(!normalizer || U_FAILURE(e) || sodium_init()<0 || FT_Init_FreeType(&ft)) return 1;
            if(!avifCodecName(AVIF_CODEC_CHOICE_AUTO, AVIF_CODEC_FLAG_CAN_ENCODE|AVIF_CODEC_FLAG_CAN_DECODE)) return 2;
            const curl_version_info_data *curl=curl_version_info(CURLVERSION_NOW);
            const int required=CURL_VERSION_HTTP2|CURL_VERSION_HTTP3|CURL_VERSION_IDN|CURL_VERSION_BROTLI|CURL_VERSION_ZSTD;
            if((curl->features & required)!=required) return 3;
            const char *requiredProtocols[]={"scp", "sftp", "ws", "wss"};
            for(const char *requiredProtocol: requiredProtocols) {
                bool found=false;
                for(const char *const *protocol=curl->protocols; *protocol; protocol++) if(strcmp(*protocol,requiredProtocol)==0) found=true;
                if(!found) return 4;
            }
            printf("icu=%s sodium=%s pq=%d zip=%s curl=%s", U_ICU_VERSION, sodium_version_string(), PQlibVersion(), zip_libzip_version(), curl->version);
            FT_Done_FreeType(ft);
            return 0;
        }
        """.utf8).write(to: source)
        let flags = try await ProcessRunner.run(executable: prepared.pkgConfig, arguments: ["--cflags", "--libs", "icu-uc", "libsodium", "libpq", "libzip", "libavif", "freetype2", "libcurl"], environment: prepared.environment, timeout: 15).requireSuccess().stdout.split(whereSeparator: \.isWhitespace).map(String.init)
        _ = try await ProcessRunner.run(executable: "/usr/bin/clang++", arguments: ["-std=c++17", source.path, "-o", binary.path] + flags, environment: prepared.environment, timeout: 45).requireSuccess()
        let result = try await ProcessRunner.run(executable: binary.path, arguments: [], environment: prepared.environment, timeout: 15).requireSuccess()
        XCTAssertTrue(result.stdout.contains("icu=77.1 sodium=1.0.20 pq=180006 zip=1.12.1"))
        let dependencies = try await ProcessRunner.run(executable: "/usr/bin/otool", arguments: ["-L", binary.path], timeout: 15).requireSuccess().stdout
        XCTAssertNoThrow(try ManagedPHPExtensionInstaller.validateDependencies(dependencies))
    }
}
