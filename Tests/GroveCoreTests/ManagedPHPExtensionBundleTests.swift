import XCTest
@testable import GroveCore

final class ManagedPHPExtensionBundleTests: XCTestCase {
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
        let bundle = try await ManagedPHPExtensionBundle.build(for: runtime, directory: build, root: build.appendingPathComponent("state")) { message in
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
