import Foundation
import Darwin

/// Maintainer-only entry points for `grove-php-release`. The desktop application
/// downloads signed packages; it never calls this build or staging workflow.
public enum ManagedPHPRelease {
    public static var architecture: String { ManagedPHPCatalog.architecture == "aarch64" ? "arm64" : "x86_64" }
    private static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PHPRC": "", "PHP_INI_SCAN_DIR": "",
        "XDEBUG_MODE": "off", "DYLD_LIBRARY_PATH": "", "DYLD_FALLBACK_LIBRARY_PATH": "", "DYLD_INSERT_LIBRARIES": ""]

    public static func build(version: String, workspace: URL, output: URL, baseline: URL? = nil,
                             progress: @escaping @Sendable (String) async -> Void) async throws {
        try checkVersion(version)
        guard workspace.path.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !FileManager.default.fileExists(atPath: output.path) else { throw GroveError.message("Use a space-free build directory and a new output directory.") }
        let state = try GrovePaths.ensureDirectory(workspace.appendingPathComponent("state"))
        let runtime: RuntimeInstallation
        if let baseline { runtime = RuntimeInstallation(family: .php, version: version, executablePath: baseline.path, source: "Grove") }
        else {
            runtime = try await ManagedPHPInstaller.installStaticPHP(.init(version: version, architecture: ManagedPHPCatalog.architecture), root: state, progress: progress)
        }
        let build = try GrovePaths.ensureDirectory(workspace.appendingPathComponent("build"))
        let result = try await ManagedPHPExtensionBundle.build(for: runtime, directory: build, root: state, progress: progress)
        try stage(result: result, output: output)
        try await verify(directory: output, version: version, baseline: URL(fileURLWithPath: runtime.executablePath))
        await progress("Validated release payload: \(output.path)")
    }

    public static func importCache(_ cache: URL, version: String, output: URL, baseline: URL) async throws {
        try checkVersion(version)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw GroveError.message("The release output already exists.") }
        // Import is an explicit maintainer operation. An old local receipt does
        // not confer release trust: every binary is tested again before signing.
        let result = ManagedPHPExtensionBundle.Bundle(php: cache.appendingPathComponent("bin/php"),
            fpm: cache.appendingPathComponent("bin/php-fpm"),
            modules: Dictionary(uniqueKeysWithValues: ["intl", "sodium", "xdebug", "spx"].map { ($0, cache.appendingPathComponent("modules/\($0).so")) }),
            spxAssets: cache.appendingPathComponent("web-ui"), licenses: cache.appendingPathComponent("licenses"))
        try stage(result: result, output: output)
        try await verify(directory: output, version: version, baseline: baseline)
    }

    private static func stage(result: ManagedPHPExtensionBundle.Bundle, output: URL) throws {
        let parent = try GrovePaths.ensureDirectory(output.deletingLastPathComponent())
        let stage = parent.appendingPathComponent(".stage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        for (name, source) in [("bin/php", result.php), ("bin/php-fpm", result.fpm)] {
            let target = stage.appendingPathComponent(name)
            _ = try GrovePaths.ensureDirectory(target.deletingLastPathComponent())
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        _ = try GrovePaths.ensureDirectory(stage.appendingPathComponent("modules"))
        for name in ["intl", "sodium", "xdebug", "spx"] {
            guard let source = result.modules[name] else { throw GroveError.message("Missing \(name) in release payload.") }
            try FileManager.default.copyItem(at: source, to: stage.appendingPathComponent("modules/\(name).so"))
        }
        try FileManager.default.copyItem(at: result.spxAssets, to: stage.appendingPathComponent("web-ui"))
        try FileManager.default.copyItem(at: result.licenses, to: stage.appendingPathComponent("licenses"))
        _ = try ManagedPHPExtensionSupport.fileDigests(in: stage)
        try FileManager.default.moveItem(at: stage, to: output)
    }

    public static func verify(directory: URL, version: String, baseline: URL) async throws {
        try checkVersion(version)
        _ = try ManagedPHPExtensionSupport.fileDigests(in: directory)
        let runtime = RuntimeInstallation(family: .php, version: version, executablePath: baseline.path, source: "Grove")
        let php = directory.appendingPathComponent("bin/php"), fpm = directory.appendingPathComponent("bin/php-fpm")
        let modules = Dictionary(uniqueKeysWithValues: ["intl", "sodium", "xdebug", "spx"].map { ($0, directory.appendingPathComponent("modules/\($0).so")) })
        for executable in [php, fpm] { try ManagedPHPInstaller.validateMachO(at: executable, architecture: ManagedPHPCatalog.architecture) }
        try await ManagedPHPExtensionBundle.validate(runtime: runtime, php: php, fpm: fpm, modules: modules, environment: environment)
        try await ManagedPHPExtensionBundle.validateBuildProvider(php: php, fpm: fpm, version: version, environment: environment)
        let result = try await ProcessRunner.run(executable: php.path, arguments: ["-n", "-d", "extension=\(modules["intl"]!.path)", "-d", "extension=\(modules["sodium"]!.path)", "-r", """
            if (bin2hex(Normalizer::normalize("e\\u{0301}")) !== "c3a9") exit(10);
            $key = sodium_crypto_secretbox_keygen(); $nonce = random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
            if (sodium_crypto_secretbox_open(sodium_crypto_secretbox('grove', $nonce, $key), $nonce, $key) !== 'grove') exit(11);
            $pair = sodium_crypto_sign_keypair(); $signature = sodium_crypto_sign_detached('grove', sodium_crypto_sign_secretkey($pair));
            if (!sodium_crypto_sign_verify_detached($signature, 'grove', sodium_crypto_sign_publickey($pair))) exit(12);
            echo 'intl+sodium verified';
            """], environment: environment, timeout: 20).requireSuccess()
        guard result.stdout == "intl+sodium verified", result.stderr.isEmpty else { throw GroveError.message("Release extension functionality failed.") }
        let temporary = URL(fileURLWithPath: "/private/tmp/GrovePHPReleaseProbe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let profiles = try GrovePaths.ensureDirectory(temporary.appendingPathComponent("profiles"))
        _ = try await ProcessRunner.run(executable: php.path, arguments: ["-n", "-d", "zend_extension=\(modules["xdebug"]!.path)", "-d", "xdebug.mode=profile", "-d", "xdebug.start_with_request=yes", "-d", "xdebug.output_dir=\(profiles.path)", "-r", "echo array_sum(range(1,10000));"], environment: environment.merging(["XDEBUG_MODE": "profile"]) { _, value in value }, timeout: 20).requireSuccess()
        _ = try await ProcessRunner.run(executable: php.path, arguments: ["-n", "-d", "extension=\(modules["spx"]!.path)", "-d", "spx.data_dir=\(profiles.path)", "-r", "echo array_sum(range(1,10000));"], environment: environment.merging(["SPX_ENABLED": "1", "SPX_REPORT": "full"]) { _, value in value }, timeout: 20).requireSuccess()
        let reports = try FileManager.default.contentsOfDirectory(atPath: profiles.path)
        guard reports.contains(where: { $0.hasPrefix("cachegrind.out.") }), reports.contains(where: { $0.hasPrefix("spx-full-") && $0.hasSuffix(".json") }) else { throw GroveError.message("Release profiling capture failed.") }
        let socket = temporary.appendingPathComponent("fpm.sock"), config = temporary.appendingPathComponent("fpm.conf")
        try PHPFPMConfiguration.pool(socket: socket, pid: temporary.appendingPathComponent("fpm.pid"), workers: 2).write(to: config, atomically: true, encoding: .utf8)
        var args = ["-n", "-F", "-y", config.path]
        for name in modules.keys.sorted() { args += ["-d", "\(name == "xdebug" ? "zend_extension" : "extension")=\(modules[name]!.path)"] }
        let task = Task { try await ProcessRunner.run(executable: fpm.path, arguments: args, environment: environment, timeout: 8) }
        var ready = false
        for _ in 0..<100 {
            var info = stat()
            if lstat(socket.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK { ready = true; break }
            try await Task.sleep(for: .milliseconds(40))
        }
        task.cancel(); _ = try? await task.value
        guard ready else { throw GroveError.message("Release PHP-FPM did not start with all four extensions.") }
    }

    private static func checkVersion(_ value: String) throws {
        guard value.range(of: #"^8\.[2-5]\.[0-9]+$"#, options: .regularExpression) != nil else { throw GroveError.message("Release builds support exact PHP 8.2–8.5 patch versions.") }
    }
}
