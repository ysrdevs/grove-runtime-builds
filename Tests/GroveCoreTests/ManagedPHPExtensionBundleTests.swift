import XCTest
@testable import GroveCore

final class ManagedPHPExtensionBundleTests: XCTestCase {
    func testBuildProviderBannerPreservesVersionAndCredits() throws {
        for version in ["8.2.33", "8.3.33", "8.4.26", "8.5.11"] {
            for sapi in ["cli", "fpm-fcgi"] {
                let banner = "PHP \(version) (\(sapi)) (built: Oct 15 2026 09:00:00) (NTS)\nCopyright (c) The PHP Group\nBuilt by Grove\nZend Engine v4.4.26, Copyright (c) Zend Technologies\n    with Zend OPcache v8.4.26, Copyright (c), by Zend Technologies\n"
                XCTAssertNoThrow(try ManagedPHPExtensionBundle.validateBuildProviderBanner(banner, version: version, sapi: sapi))
                for invalid in [banner.replacingOccurrences(of: "Built by Grove\n", with: ""),
                                banner.replacingOccurrences(of: "Built by Grove", with: "Built by Another Provider"),
                                banner.replacingOccurrences(of: "Copyright (c) The PHP Group\n", with: ""),
                                banner.replacingOccurrences(of: "PHP \(version) (", with: "PHP \(version)-grove ("),
                                banner + "Built by Grove\n"] {
                    XCTAssertThrowsError(try ManagedPHPExtensionBundle.validateBuildProviderBanner(invalid, version: version, sapi: sapi))
                }
            }
        }
    }

    func testLegacyProviderPatchPreservesCreditsAndFailsOnChangedSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GrovePHPProviderPatch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("sapi/cli/php_cli.c")
        let fpm = root.appendingPathComponent("sapi/fpm/fpm/fpm_main.c")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fpm.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cliOriginal = #"php_printf("PHP %s (%s) (built: %s %s) (%s)\nCopyright (c) The PHP Group\n%s", PHP_VERSION, cli_sapi_module.name, __DATE__, __TIME__, "NTS", get_zend_version());"#
        let fpmOriginal = "#if ZEND_DEBUG\n" + cliOriginal + "\n#else\n" + cliOriginal + "\n#endif\n"
        for version in ["8.2.33", "8.3.33"] {
            try cliOriginal.write(to: cli, atomically: true, encoding: .utf8)
            try fpmOriginal.write(to: fpm, atomically: true, encoding: .utf8)
            try ManagedPHPExtensionBundle.patchLegacyBuildProvider(version: version, source: root)
            let patched = try String(contentsOf: cli, encoding: .utf8)
            XCTAssertTrue(patched.contains(#"Copyright (c) The PHP Group\nBuilt by " PHP_BUILD_PROVIDER "\n%s"#))
            XCTAssertTrue(patched.contains("PHP_VERSION, cli_sapi_module.name, __DATE__, __TIME__, \"NTS\", get_zend_version()"))
            XCTAssertEqual(try String(contentsOf: fpm, encoding: .utf8).components(separatedBy: "PHP_BUILD_PROVIDER").count, 3)
            XCTAssertThrowsError(try ManagedPHPExtensionBundle.patchLegacyBuildProvider(version: version, source: root))
            try cliOriginal.write(to: cli, atomically: true, encoding: .utf8)
            try "unexpected upstream source".write(to: fpm, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try ManagedPHPExtensionBundle.patchLegacyBuildProvider(version: version, source: root))
            XCTAssertEqual(try String(contentsOf: cli, encoding: .utf8), cliOriginal, "A failed source check must not partially patch the other SAPI.")
        }
        // Modern versions already use PHP_BUILD_PROVIDER through their shared
        // upstream banner; this compatibility patch must leave them alone.
        for version in ["8.4.26", "8.5.11"] {
            try ManagedPHPExtensionBundle.patchLegacyBuildProvider(version: version, source: root)
            XCTAssertEqual(try String(contentsOf: cli, encoding: .utf8), cliOriginal)
        }
    }

    func testProviderPatchAgainstDownloadedOfficialSources() throws {
        guard let sources = ProcessInfo.processInfo.environment["GROVE_PHP_PROVIDER_SOURCES"] else {
            throw XCTSkip("Set GROVE_PHP_PROVIDER_SOURCES to colon-separated official PHP source directories to dry-run the compatibility patch.")
        }
        for path in sources.split(separator: ":") {
            let source = URL(fileURLWithPath: String(path))
            let version = String(source.lastPathComponent.dropFirst("php-".count))
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GrovePHPProviderSource-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            for relative in ["sapi/cli/php_cli.c", "sapi/fpm/fpm/fpm_main.c"] {
                let destination = temporary.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source.appendingPathComponent(relative), to: destination)
            }
            try ManagedPHPExtensionBundle.patchLegacyBuildProvider(version: version, source: temporary)
            if version.hasPrefix("8.2.") || version.hasPrefix("8.3.") {
                for relative in ["sapi/cli/php_cli.c", "sapi/fpm/fpm/fpm_main.c"] {
                    let patched = try String(contentsOf: temporary.appendingPathComponent(relative), encoding: .utf8)
                    XCTAssertTrue(patched.contains(#"Built by " PHP_BUILD_PROVIDER "\n"#), version + " " + relative)
                }
            } else {
                let shared = try String(contentsOf: source.appendingPathComponent("main/main.c"), encoding: .utf8)
                XCTAssertTrue(shared.contains("PHP_BUILD_PROVIDER"), version)
                XCTAssertTrue(shared.contains("Built by "), version)
            }
        }
    }

    func testRejectsNetworkFeatureAndProtocolLoss() {
        let features = ["HTTP2": true, "HTTP3": true, "IDN": true, "BROTLI": true, "ZSTD": true]
        let protocols = ["https", "scp", "sftp", "ws", "wss"]
        XCTAssertTrue(ManagedPHPExtensionBundle.preservesCurlCapabilities(originalFeatures: features, originalProtocols: protocols,
            candidateFeatures: features.merging(["SSL": true]) { _, value in value }, candidateProtocols: protocols + ["ipfs"]))
        XCTAssertFalse(ManagedPHPExtensionBundle.preservesCurlCapabilities(originalFeatures: features, originalProtocols: protocols,
            candidateFeatures: features.merging(["HTTP3": false]) { _, value in value }, candidateProtocols: protocols))
        XCTAssertFalse(ManagedPHPExtensionBundle.preservesCurlCapabilities(originalFeatures: features, originalProtocols: protocols,
            candidateFeatures: features, candidateProtocols: ["https", "ws", "wss"]))
    }
    func testArchiveListingRetainsEveryEntry() async throws {
        guard let path = ProcessInfo.processInfo.environment["GROVE_PHP_ARCHIVE_TEST_PATH"] else { throw XCTSkip("Set GROVE_PHP_ARCHIVE_TEST_PATH to verify the complete upstream archive listing.") }
        let environment = ["LC_ALL": "en_US.UTF-8", "PATH": PHPBuildSupport.systemPath]
        let names = try await ProcessRunner.run(executable: "/usr/bin/tar", arguments: ["-tf", path], environment: environment, timeout: 90, outputLimit: 16_000_000).requireSuccess().stdout
        let listing = try await ProcessRunner.run(executable: "/usr/bin/tar", arguments: ["-tvf", path], environment: environment, timeout: 90, outputLimit: 16_000_000).requireSuccess().stdout
        print("Archive names: \(names.utf8.count) bytes, \(names.split(separator: "\n").count) lines; details: \(listing.utf8.count) bytes, \(listing.split(separator: "\n").count) lines")
        try PHPBuildSupport.validateArchive(names: names, listing: listing, maximumBytes: 512_000_000)
    }
    func testOptionalModulesStaySharedAndModernPostgresUsesStaticMetadata() {
        let arguments = ManagedPHPExtensionBundle.configureArguments(version: "8.5.11", prefix: URL(fileURLWithPath: "/private/tmp/libs"), output: URL(fileURLWithPath: "/private/tmp/output"))
        XCTAssertTrue(arguments.contains("--enable-intl=shared"))
        XCTAssertTrue(arguments.contains("--with-sodium=shared"))
        XCTAssertFalse(arguments.contains("--enable-intl"))
        XCTAssertFalse(arguments.contains("--with-sodium"))
        XCTAssertTrue(arguments.contains("--with-pgsql"))
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("--with-pgsql=") }))
        XCTAssertTrue(arguments.contains("--with-config-file-scan-dir=/var/empty"))
    }

    func testOlderPHPKeepsStaticOpcacheAndPrivatePostgres() {
        let arguments = ManagedPHPExtensionBundle.configureArguments(version: "8.3.31", prefix: URL(fileURLWithPath: "/private/tmp/libs"), output: URL(fileURLWithPath: "/private/tmp/output"))
        XCTAssertTrue(arguments.contains("--enable-opcache"))
        XCTAssertTrue(arguments.contains("--with-pgsql=/private/tmp/libs"))
        XCTAssertFalse(arguments.contains("--with-openssl-argon2"))
        let withoutOpcache = ManagedPHPExtensionBundle.configureArguments(version: "8.4.26", prefix: URL(fileURLWithPath: "/private/tmp/libs"), output: URL(fileURLWithPath: "/private/tmp/output"), includeOpcache: false)
        XCTAssertTrue(withoutOpcache.contains("--disable-opcache"))
        XCTAssertFalse(withoutOpcache.contains("--enable-opcache"))
    }

    func testExistingBundleRetainsExactModuleVersions() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["GROVE_PHP_EXTENSION_EXISTING_BUNDLE"], let binary = environment["GROVE_PHP_EXTENSION_TEST_BINARY"] else {
            throw XCTSkip("Set GROVE_PHP_EXTENSION_EXISTING_BUNDLE and GROVE_PHP_EXTENSION_TEST_BINARY to validate a completed private build again.")
        }
        let version = try await ProcessRunner.run(executable: binary, arguments: ["-n", "-r", "echo PHP_VERSION;"], timeout: 15).requireSuccess().stdout
        let runtime = RuntimeInstallation(family: .php, version: version, executablePath: binary, source: "Grove")
        let directory = URL(fileURLWithPath: path), source = directory.appendingPathComponent("source/php-\(version)")
        let modules = ["intl": source.appendingPathComponent("modules/intl.so"), "sodium": source.appendingPathComponent("modules/sodium.so"),
                       "xdebug": directory.appendingPathComponent("modules/xdebug.so"), "spx": directory.appendingPathComponent("modules/spx.so")]
        try await ManagedPHPExtensionBundle.validate(runtime: runtime, php: source.appendingPathComponent("sapi/cli/php"),
            fpm: source.appendingPathComponent("sapi/fpm/php-fpm"), modules: modules, environment: ["PATH": PHPBuildSupport.systemPath])
        if environment["GROVE_PHP_VERIFY_PARITY"] == "1" {
            try await ManagedPHPExtensionBundle.validateParity(php: source.appendingPathComponent("sapi/cli/php"), environment: ["PATH": PHPBuildSupport.systemPath])
        }
    }

    func testBuildsActualManagedRuntimeAndGeneratesProfilesWithoutHomebrew() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GROVE_PHP_EXTENSION_BUNDLE_TESTS"] == "1", let binary = environment["GROVE_PHP_EXTENSION_TEST_BINARY"] else {
            throw XCTSkip("Set GROVE_PHP_EXTENSION_BUNDLE_TESTS=1 and GROVE_PHP_EXTENSION_TEST_BINARY to build an isolated complete extension bundle.")
        }
        let build = URL(fileURLWithPath: "/private/tmp/GrovePHPBundleTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let version = try await ProcessRunner.run(executable: binary, arguments: ["-n", "-r", "echo PHP_VERSION;"], timeout: 15).requireSuccess().stdout
        let runtime = RuntimeInstallation(family: .php, version: version, executablePath: binary, source: "Grove")
        // Keep the disposable tree on failure so compiler output is reviewable.
        var preparedLibraries: ManagedPHPDependencyBuilder.Prepared?
        if let fixture = environment["GROVE_PHP_PREPARED_LIBRARY_FIXTURE"] {
            guard fixture.hasPrefix("/private/tmp/GrovePHPParity") else { throw GroveError.message("Parity library fixtures must use a private test workspace.") }
            let prefix = URL(fileURLWithPath: fixture)
            var compiler = try await PHPBuildSupport.compilerEnvironment()
            let pkgConfig = prefix.appendingPathComponent("bin/pkg-config").path
            compiler["PKG_CONFIG"] = pkgConfig
            compiler["PKG_CONFIG_LIBDIR"] = prefix.appendingPathComponent("lib/pkgconfig").path
            compiler["CPPFLAGS"] = "-I\(prefix.path)/include"
            compiler["LDFLAGS"] = "-L\(prefix.path)/lib"
            let sdk = compiler["SDKROOT"]!
            compiler["LIBXML_CFLAGS"] = "-I\(sdk)/usr/include/libxml2"; compiler["LIBXML_LIBS"] = "-lxml2"
            compiler.merge(ManagedPHPParityDependencies.systemEnvironment(sdk: sdk)) { _, value in value }
            for (name, flag, library) in [("CURL_CFLAGS", "--cflags", "libcurl"), ("CURL_LIBS", "--libs", "libcurl"), ("PGSQL_LIBS", "--libs", "libpq")] {
                compiler[name] = try await ProcessRunner.run(executable: pkgConfig, arguments: [flag, library], environment: compiler, timeout: 15).requireSuccess().stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            compiler["PGSQL_CFLAGS"] = "-I\(prefix.path)/include"
            preparedLibraries = .init(prefix: prefix, environment: compiler, pkgConfig: pkgConfig)
        }
        let bundle = try await ManagedPHPExtensionBundle.build(for: runtime, directory: build, root: build.appendingPathComponent("state"), preparedLibraries: preparedLibraries) { message in
            print("PHP bundle: \(message)")
        }
        let profile = try GrovePaths.ensureDirectory(build.appendingPathComponent("profiles"))
        let xdebug = try XCTUnwrap(bundle.modules["xdebug"])
        let xdebugResult = try await ProcessRunner.run(executable: bundle.php.path,
            arguments: ["-n", "-d", "zend_extension=\(xdebug.path)", "-d", "xdebug.mode=profile", "-d", "xdebug.start_with_request=yes", "-d", "xdebug.output_dir=\(profile.path)", "-r", "echo array_sum(range(1,10000));"],
            environment: ["PATH": PHPBuildSupport.systemPath, "XDEBUG_MODE": "profile"], timeout: 20).requireSuccess()
        XCTAssertEqual(xdebugResult.stdout, "50005000")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: profile.path).contains(where: { $0.hasPrefix("cachegrind.out.") }))
        let spx = try XCTUnwrap(bundle.modules["spx"])
        let spxResult = try await ProcessRunner.run(executable: bundle.php.path,
            arguments: ["-n", "-d", "extension=\(spx.path)", "-d", "spx.data_dir=\(profile.path)", "-r", "echo array_sum(range(1,10000));"],
            environment: ["PATH": PHPBuildSupport.systemPath, "SPX_ENABLED": "1", "SPX_REPORT": "full"], timeout: 20).requireSuccess()
        XCTAssertEqual(spxResult.stdout, "50005000")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: profile.path).contains(where: { $0.hasPrefix("spx-full-") && $0.hasSuffix(".json") }))
        print("Verified PHP bundle at \(build.path)")
        if environment["GROVE_PHP_EXTENSION_KEEP_TEST_BUILD"] != "1" { try FileManager.default.removeItem(at: build) }
    }
}
