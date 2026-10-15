import Foundation

/// A complete, isolated PHP build which retains the public engine API needed by
/// optional extensions. The downloaded common binaries discard some of those
/// symbols. Nothing here replaces a runtime or changes a user's PHP settings.
enum ManagedPHPExtensionBundle {
    struct Bundle: Sendable {
        let php: URL
        let fpm: URL
        let modules: [String: URL]
        let spxAssets: URL
        let licenses: URL
    }

    private struct Source {
        let name: String
        let version: String
        let sha256: String
        var url: URL {
            if name == "lz4" { return URL(string: "https://codeload.github.com/kjdev/php-ext-lz4/tar.gz/refs/tags/\(version)")! }
            if name == "imagick" { return URL(string: "https://codeload.github.com/Imagick/imagick/tar.gz/refs/tags/\(version)")! }
            return URL(string: "https://pecl.php.net/get/\(name)-\(version).tgz")!
        }
        var topDirectory: String { name == "lz4" ? "php-ext-lz4-\(version)" : "\(name)-\(version)" }
    }
    private static let extensions: [Source] = [
        .init(name: "apcu", version: "5.1.28", sha256: "ca9c1820810a168786f8048a4c3f8c9e3fd941407ad1553259fb2e30b5f057bf"),
        .init(name: "redis", version: "6.3.0", sha256: "0d5141f634bd1db6c1ddcda053d25ecf2c4fc1c395430d534fd3f8d51dd7f0b5"),
        .init(name: "igbinary", version: "3.2.17RC1", sha256: "91da821443db125282a6aea039f24588dd28ff5d71e8187f6ecc41165bceafbc"),
        .init(name: "msgpack", version: "3.0.1", sha256: "e30be355ab79aaea4568692fbd6073fd7c7f50ea8d3cf12edce40fc0c921d868"),
        .init(name: "imagick", version: "3.8.1", sha256: "b0e9279ddf6e75a8c6b4068e16daec0475427dbca7ce2e144e30a51a88aa5ddc"),
        .init(name: "mongodb", version: "2.5.4", sha256: "41eead0799cc66876b12d10b5efe86268bfc704c1be57a70d49e4bd4bf6c8ee1"),
        .init(name: "zstd", version: "0.18.0", sha256: "223d0f77eb5a5e73cf5e7a0652dd8fde7ffdcc843e7f30eeb3998283dec847b9"),
        .init(name: "lz4", version: "0.7.1", sha256: "e5913a346c65ed5d3d487398332a66629db2c863e02dfe0e949f653471853fcc")
    ]
    private static let sqlExtensions: [Source] = [
        .init(name: "sqlsrv", version: "5.13.3", sha256: "1c3092ca793bb67002ca022c412aacabb79a3297ee7005e3b7cc91b1e7166d22"),
        .init(name: "pdo_sqlsrv", version: "5.13.3", sha256: "198a7b37da0658d36a93d158a0ec179b137b3a4d241c90a6650ae9ee8f91ec4a")
    ]
    private static let imapExtension = Source(name: "imap", version: "1.0.3", sha256: "0c2c0b1f94f299004be996b85a424e3d11ff65ac0a3c980db3213289a4a3faaf")
    static let additionalBuiltInModules: Set<String> = ["dba", "ffi", "gettext", "imagick", "imap", "ldap", "lz4", "mongodb", "pdo_sqlsrv", "readline", "shmop", "sqlsrv", "sysvmsg", "sysvsem", "sysvshm", "xsl", "zstd"]
    private static let jobs = String(min(8, ProcessInfo.processInfo.activeProcessorCount))

    static func build(for runtime: RuntimeInstallation, directory: URL, root: URL,
                      preparedLibraries: ManagedPHPDependencyBuilder.Prepared? = nil,
                      progress: @escaping @Sendable (String) async -> Void) async throws -> Bundle {
        guard runtime.source == "Grove" else { throw GroveError.message("Only Grove's managed PHP can be prepared with this installer.") }
        let kit = try await PHPBuildSupport.source(for: runtime, directory: directory.appendingPathComponent("source"), root: root, progress: progress)
        try patchLegacyBuildProvider(version: runtime.version, source: kit.directory)
        let opcacheProbe = try await ProcessRunner.run(executable: runtime.executablePath,
            arguments: ["-n", "-r", "echo extension_loaded('Zend OPcache') ? '1' : '0';"], environment: kit.environment, timeout: 15).requireSuccess()
        guard ["0", "1"].contains(opcacheProbe.stdout), opcacheProbe.stderr.isEmpty else { throw GroveError.message("The installed PHP extension inventory could not be read.") }
        let includeOpcache = true
        let licenses = try GrovePaths.ensureDirectory(directory.appendingPathComponent("licenses"))
        try copyNotices(from: kit.directory, to: licenses.appendingPathComponent("PHP"))
        await progress("Preparing PHP's build tools…")
        let tools = try await buildTools(directory: directory, root: root, environment: kit.environment)
        var sources = extensions
        if runtime.version.compare("8.4", options: .numeric) != .orderedAscending {
            sources.append(imapExtension)
        }
        // 5.13 contains upstream memory-safety fixes missing from 5.12.
        // Grove also exercises 5.13 on PHP 8.2; Microsoft officially supports 8.3+.
        sources += sqlExtensions
        for source in sources {
            await progress("Preparing \(source.name) \(source.version)…")
            let archive = try await PHPBuildSupport.download(url: source.url, sha256: source.sha256, maximumBytes: 8_000_000, root: root)
            let unpack = directory.appendingPathComponent("sources/\(source.name)")
            try await PHPBuildSupport.extract(archive: archive, to: unpack)
            let sourceDirectory = unpack.appendingPathComponent(source.topDirectory)
            try copyNotices(from: sourceDirectory, to: licenses.appendingPathComponent(source.name))
            try FileManager.default.copyItem(at: sourceDirectory, to: kit.directory.appendingPathComponent("ext/\(source.name)"))
        }
        try patchParityExtensions(source: kit.directory)
        if includeOpcache {
            try await patchStaticOpcache(version: runtime.version, source: kit.directory, root: root, environment: kit.environment, logs: directory, licenses: licenses)
        }
        var environment = kit.environment
        environment["PATH"] = tools.appendingPathComponent("bin").path + ":" + PHPBuildSupport.systemPath
        try await command(kit.directory.appendingPathComponent("buildconf").path, ["--force"], source: kit.directory, environment: environment, logs: directory, name: "php-buildconf", timeout: 180)
        let libraries: ManagedPHPDependencyBuilder.Prepared
        if let preparedLibraries { libraries = preparedLibraries }
        else { libraries = try await ManagedPHPExtensionInstaller.prepareLibraries(directory: directory.appendingPathComponent("libraries"), root: root, progress: progress) }
        try FileManager.default.copyItem(at: libraries.prefix.appendingPathComponent("source-licenses"), to: licenses.appendingPathComponent("libraries"))
        environment.merge(libraries.environment) { _, new in new }
        environment["PATH"] = tools.appendingPathComponent("bin").path + ":" + PHPBuildSupport.systemPath
        environment["PKG_CONFIG"] = libraries.pkgConfig
        // GNU gettext reads macOS language preferences through CoreFoundation.
        // Keep the framework available during configure's static link probes.
        environment["LDFLAGS"] = "-L\(libraries.prefix.path)/lib -Wl,-export_dynamic -framework CoreFoundation"
        // PHP uses this compile-time provider in phpinfo(), and since 8.4 in
        // both native version banners. Older SAPIs receive the same display below.
        environment["PHP_BUILD_PROVIDER"] = "Grove"
        let components = runtime.version.split(separator: ".").compactMap { Int($0) }
        environment["PHP_VERSION_ID"] = String(components[0] * 10_000 + components[1] * 100 + components[2])
        environment["PHP_VERSION"] = runtime.version
        if runtime.version.compare("8.4", options: .numeric) == .orderedAscending {
            // Older PHP configure scripts use pg_config and omit libpq's static
            // transitive libraries from their feature probes and final link.
            environment["LIBS"] = libraries.environment["PGSQL_LIBS"]
            // The older link-only probe can find a private dependency's
            // explicit_bzero without a matching SDK declaration. PHP's own
            // implementation preserves secure zeroing with a compiler barrier.
            environment["ac_cv_func_explicit_bzero"] = "no"
        }
        await progress("Configuring PHP \(runtime.version) and optional extensions…")
        try await command(kit.directory.appendingPathComponent("configure").path,
                          configureArguments(version: runtime.version, prefix: libraries.prefix, output: directory.appendingPathComponent("output"), includeOpcache: includeOpcache),
                          source: kit.directory, environment: environment, logs: directory, name: "php-configure", timeout: 360)
        await progress("Building PHP \(runtime.version) with extension support…")
        try await command("/usr/bin/make", ["-j", jobs], source: kit.directory, environment: environment, logs: directory, name: "php-make", timeout: 1_800)
        let php = kit.directory.appendingPathComponent("sapi/cli/php"), fpm = kit.directory.appendingPathComponent("sapi/fpm/php-fpm")
        let output = try GrovePaths.ensureDirectory(directory.appendingPathComponent("modules"))
        await progress("Building Xdebug and SPX…")
        let debugging = try await buildDebuggers(source: kit.directory, directory: directory, output: output, root: root, environment: kit.environment, licenses: licenses)
        let modules: [String: URL] = ["intl": kit.directory.appendingPathComponent("modules/intl.so"), "sodium": kit.directory.appendingPathComponent("modules/sodium.so"), "xdebug": debugging.xdebug, "spx": debugging.spx]
        await progress("Checking PHP, FPM, and all four extensions…")
        try await validate(runtime: runtime, php: php, fpm: fpm, modules: modules, environment: kit.environment)
        try await validateBuildProvider(php: php, fpm: fpm, version: runtime.version, environment: kit.environment)
        try await validateParity(php: php, environment: kit.environment)
        try Task.checkCancellation()
        return Bundle(php: php, fpm: fpm, modules: modules, spxAssets: debugging.assets, licenses: licenses)
    }

    static func patchLegacyBuildProvider(version: String, source: URL) throws {
        guard version.hasPrefix("8.2.") || version.hasPrefix("8.3.") else { return }
        // PHP 8.2/8.3 already expose PHP_BUILD_PROVIDER to phpinfo(), but their
        // individual CLI/FPM banner functions predate the shared 8.4 implementation.
        // Keep PHP_VERSION and all upstream credits intact. Fail closed if an
        // upstream edit changes either expected banner, rather than patching loosely.
        let original = #"Copyright (c) The PHP Group\n%s"#
        let branded = #"Copyright (c) The PHP Group\nBuilt by " PHP_BUILD_PROVIDER "\n%s"#
        let patches = try [("sapi/cli/php_cli.c", 1), ("sapi/fpm/fpm/fpm_main.c", 2)].map { path, count -> (URL, String) in
            let file = source.appendingPathComponent(path)
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.components(separatedBy: original).count == count + 1,
                  !text.contains(branded) else {
                throw GroveError.message("PHP's \(path) version banner changed. Review the Grove build-provider patch before releasing this version.")
            }
            return (file, text.replacingOccurrences(of: original, with: branded))
        }
        for (file, text) in patches { try text.write(to: file, atomically: true, encoding: .utf8) }
    }

    static func validateBuildProvider(php: URL, fpm: URL, version: String, environment: [String: String]) async throws {
        for (binary, sapi) in [(php, "cli"), (fpm, "fpm-fcgi")] {
            let result = try await ProcessRunner.run(executable: binary.path, arguments: ["-n", "-v"], environment: environment, timeout: 15).requireSuccess()
            try validateBuildProviderBanner(result.stdout, version: version, sapi: sapi)
            guard result.stderr.isEmpty else { throw GroveError.message("The Grove PHP version banner emitted a startup warning.") }
        }
    }

    static func validateBuildProviderBanner(_ banner: String, version: String, sapi: String) throws {
        let lines = banner.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 4, lines[0].hasPrefix("PHP \(version) (\(sapi)) (built: "),
              lines[1] == "Copyright (c) The PHP Group", lines[2] == "Built by Grove",
              lines[3].hasPrefix("Zend Engine v"), lines.filter({ $0 == "Built by Grove" }).count == 1 else {
            throw GroveError.message("The completed PHP release is missing Grove's build provider or the upstream version credits.")
        }
    }

    static func patchParityExtensions(source: URL) throws {
        // The upstream Git tag uses PECL's packaging placeholder. Apply its
        // declared package-info replacement while preserving all source credits.
        let imagickHeader = source.appendingPathComponent("ext/imagick/php_imagick.h")
        let imagickText = try String(contentsOf: imagickHeader, encoding: .utf8)
        guard imagickText.components(separatedBy: "@PACKAGE_VERSION@").count == 2,
              let imagickVersion = extensions.first(where: { $0.name == "imagick" })?.version else {
            throw GroveError.message("Review Imagick's package version declaration before releasing this source version.")
        }
        try imagickText.replacingOccurrences(of: "@PACKAGE_VERSION@", with: imagickVersion)
            .write(to: imagickHeader, atomically: true, encoding: .utf8)
        for name in ["sqlsrv", "pdo_sqlsrv"] {
            let config = source.appendingPathComponent("ext/\(name)/config.m4")
            let text = try String(contentsOf: config, encoding: .utf8)
            guard text.components(separatedBy: "PHP_ADD_LIBRARY(stdc++,").count == 2 else {
                throw GroveError.message("Review \(name)'s C++ runtime configuration before releasing this source version.")
            }
            try text.replacingOccurrences(of: "PHP_ADD_LIBRARY(stdc++,", with: "PHP_ADD_LIBRARY(c++,")
                .write(to: config, atomically: true, encoding: .utf8)
        }
        let imapConfig = source.appendingPathComponent("ext/imap/config.m4")
        let imapText = try String(contentsOf: imapConfig, encoding: .utf8)
        try imapText.replacingOccurrences(of: "TST_LIBS=\"$DLIBS $IMAP_SHARED_LIBADD\"", with: "TST_LIBS=\"$DLIBS $IMAP_SHARED_LIBADD -lz\"")
            .write(to: imapConfig, atomically: true, encoding: .utf8)
    }

    /// Exercise actual APIs, not just the module listing. No network service or
    /// shared machine configuration is needed by these release acceptance probes.
    static func validateParity(php: URL, environment: [String: String]) async throws {
        let expected = additionalBuiltInModules.sorted().map { "'\($0)'" }.joined(separator: ",")
        let versions = (extensions + sqlExtensions).filter { additionalBuiltInModules.contains($0.name) }
            .map { "'\($0.name)' => '\($0.version)'" }.joined(separator: ",")
        let script = #"""
        $required = [REQUIRED];
        $loaded = array_map('strtolower', get_loaded_extensions());
        foreach ($required as $module) { if (!in_array($module, $loaded, true)) throw new Exception('Missing extension '.$module); }
        foreach ([VERSIONS] as $module => $version) {
            if (phpversion($module) !== $version) throw new Exception('Unexpected '.$module.' version: '.phpversion($module));
        }
        if (phpversion('imap') !== (PHP_VERSION_ID >= 80400 ? 'IMAP_VERSION' : PHP_VERSION)) throw new Exception('Unexpected IMAP version');
        if (FFI::cdef('int abs(int);')->abs(-7) !== 7) throw new Exception('FFI call failed');
        if (gettext('Grove') !== 'Grove') throw new Exception('gettext failed');
        $image = new Imagick(); $image->newImage(16, 12, 'red'); $image->setImageFormat('png');
        $copy = new Imagick(); $copy->readImageBlob($image->getImageBlob()); $copy->thumbnailImage(8, 6);
        if ($copy->getImageWidth() !== 8 || $copy->getImageHeight() !== 6) throw new Exception('ImageMagick failed');
        if (imap_utf8('=?UTF-8?B?R3JvdmU=?=') !== 'Grove') throw new Exception('IMAP decoding failed');
        if (ldap_escape('a*b', '', LDAP_ESCAPE_FILTER) !== 'a\2ab') throw new Exception('LDAP escaping failed');
        $oid = new MongoDB\BSON\ObjectId(); if (strlen((string)$oid) !== 24) throw new Exception('MongoDB BSON failed');
        foreach (['zstd', 'lz4'] as $codec) {
            $compress = $codec.'_compress'; $uncompress = $codec.'_uncompress';
            if ($uncompress($compress('Grove round trip')) !== 'Grove round trip') throw new Exception($codec.' failed');
        }
        $xml = new DOMDocument(); $xml->loadXML('<root>Grove</root>');
        $xsl = new DOMDocument(); $xsl->loadXML('<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:output method="text"/><xsl:template match="/"><xsl:value-of select="root"/></xsl:template></xsl:stylesheet>');
        $processor = new XSLTProcessor(); $processor->importStylesheet($xsl);
        if ($processor->transformToXml($xml) !== 'Grove') throw new Exception('XSLT failed');
        if (!function_exists('sqlsrv_configure') || !in_array('sqlsrv', PDO::getAvailableDrivers(), true)) throw new Exception('SQL Server extension registration failed');
        if (!function_exists('readline') || !function_exists('shmop_open') || !function_exists('msg_get_queue') || !function_exists('sem_get') || !function_exists('shm_attach')) throw new Exception('System APIs missing');
        $path = tempnam(sys_get_temp_dir(), 'grove-dba-');
        try {
            $db = dba_open($path, 'n', 'flatfile');
            if (!$db || !dba_insert('grove', 'ready', $db) || dba_fetch('grove', $db) !== 'ready') throw new Exception('DBA failed');
            dba_close($db);
        } finally { @unlink($path); }
        echo 'Grove extension parity verified';
        """#.replacingOccurrences(of: "REQUIRED", with: expected)
            .replacingOccurrences(of: "VERSIONS", with: versions)
            .replacingOccurrences(of: "IMAP_VERSION", with: imapExtension.version)
        let result = try await ProcessRunner.run(executable: php.path, arguments: ["-n", "-d", "ffi.enable=true", "-r", script], environment: environment, timeout: 30).requireSuccess()
        guard result.stdout == "Grove extension parity verified", result.stderr.isEmpty else {
            throw GroveError.message("The additional PHP extensions did not pass their native API checks.\n" + result.stdout + result.stderr)
        }
    }

    static func configureArguments(version: String, prefix: URL, output: URL, includeOpcache: Bool = true) -> [String] {
        var arguments = ["--disable-all", "--disable-cgi", "--disable-phpdbg", "--without-pear", "--enable-cli", "--enable-fpm", "--with-pic", "--enable-rtld-now",
            "--prefix=\(output.path)", "--with-config-file-path=/var/empty", "--with-config-file-scan-dir=/var/empty",
            "--enable-bcmath", "--with-bz2=\(prefix.path)", "--enable-calendar", "--enable-ctype", "--with-curl", "--with-libxml",
            "--enable-xml", "--enable-dom", "--enable-exif", "--enable-fileinfo", "--enable-filter", "--with-zlib", "--with-openssl",
            "--enable-ftp", "--enable-gd", "--with-freetype", "--with-jpeg", "--with-webp", "--with-avif", "--with-gmp=\(prefix.path)", "--with-iconv=\(prefix.path)",
            "--enable-mbstring", "--enable-mbregex", "--enable-mysqlnd", "--with-mysqli", "--enable-pcntl", "--enable-pdo", "--with-pdo-mysql", "--with-sqlite3", "--with-pdo-sqlite",
            "--with-pgsql", "--with-pdo-pgsql", "--enable-phar", "--enable-posix", "--enable-session",
            "--enable-apcu", "--enable-igbinary", "--with-msgpack", "--enable-redis", "--enable-redis-session", "--enable-redis-igbinary", "--enable-redis-msgpack",
            "--disable-redis-lzf", "--enable-redis-zstd", "--with-libzstd=\(prefix.path)", "--enable-redis-lz4", "--with-liblz4=\(prefix.path)",
            "--enable-simplexml", "--enable-soap", "--enable-sockets", "--enable-tokenizer", "--enable-xmlwriter", "--enable-xmlreader", "--with-zip",
            "--enable-intl=shared", "--with-sodium=shared",
            "--enable-dba", "--enable-inifile", "--enable-flatfile", "--with-ffi", "--with-gettext=\(prefix.path)",
            "--with-imagick=\(prefix.path)", "--with-imap=\(prefix.path)", "--with-imap-ssl=\(prefix.path)", "--with-ldap=\(prefix.path)",
            "--with-libedit", "--enable-shmop", "--enable-sysvmsg", "--enable-sysvsem", "--enable-sysvshm", "--with-xsl",
            "--enable-mongodb", "--with-mongodb-system-libs=no", "--with-mongodb-client-side-encryption=no", "--with-mongodb-sasl=no",
            "--with-mongodb-ssl=openssl", "--with-mongodb-zstd=yes", "--with-mongodb-zlib=yes",
            "--enable-lz4", "--with-lz4-includedir=\(prefix.path)", "--enable-zstd", "--enable-sqlsrv", "--with-pdo_sqlsrv"]
        if version.compare("8.4", options: .numeric) != .orderedAscending { arguments.append("--with-openssl-argon2") }
        else {
            arguments.removeAll { $0 == "--with-pgsql" || $0 == "--with-pdo-pgsql" }
            arguments += ["--with-pgsql=\(prefix.path)", "--with-pdo-pgsql=\(prefix.path)"]
        }
        if version.compare("8.5", options: .numeric) == .orderedAscending { arguments.append(includeOpcache ? "--enable-opcache" : "--disable-opcache") }
        return arguments
    }

    private static func buildTools(directory: URL, root: URL, environment: [String: String]) async throws -> URL {
        let prefix = directory.appendingPathComponent("tools")
        let packages = [("m4", "1.4.20", "6ac4fc31ce440debe63987c2ebbf9d7b6634e67a7c3279257dc7361de8bdb3ef"),
                        ("autoconf", "2.72", "afb181a76e1ee72832f6581c0eddf8df032b83e2e0239ef79ebedc4467d92d6e")]
        var environment = environment
        environment["PATH"] = prefix.appendingPathComponent("bin").path + ":" + PHPBuildSupport.systemPath
        for (name, version, digest) in packages {
            let archive = try await PHPBuildSupport.download(url: URL(string: "https://ftp.gnu.org/gnu/\(name)/\(name)-\(version).tar.gz")!, sha256: digest, maximumBytes: 8_000_000, root: root)
            let unpack = directory.appendingPathComponent("tool-sources/\(name)")
            try await PHPBuildSupport.extract(archive: archive, to: unpack)
            let source = unpack.appendingPathComponent("\(name)-\(version)")
            // GNU m4 can create a self-referential GNUmakefile link when macOS
            // spells the same source directory as /tmp and /private/tmp.
            let build = try GrovePaths.ensureDirectory(directory.appendingPathComponent("tool-build/\(name)"))
            try await command(source.appendingPathComponent("configure").path, ["--prefix=\(prefix.path)"], source: build, environment: environment, logs: directory, name: "\(name)-configure", timeout: 180)
            try await command("/usr/bin/make", ["-j", jobs], source: build, environment: environment, logs: directory, name: "\(name)-make", timeout: 300)
            try await command("/usr/bin/make", ["install"], source: build, environment: environment, logs: directory, name: "\(name)-install", timeout: 120)
        }
        return prefix
    }

    private static func patchStaticOpcache(version: String, source: URL, root: URL, environment: [String: String], logs: URL, licenses: URL) async throws {
        let line = version.split(separator: ".").prefix(2).joined()
        let digests = ["82": "36e0cbbca936d10d1a9184f52598f9ed5a059648702d01ab5d0b7aaebd205a7a", "83": "b35980cca7102a5335c19fa2b340dee3101f2ceed7c489966c9edc3ba035d6d4", "84": "be604e91b275b3de5c86096f1defff043f702c1207d6c28c446bb2637b1e9882"]
        guard let digest = digests[line] else { return }
        let url = URL(string: "https://raw.githubusercontent.com/crazywhalecc/static-php-cli/c2b02e4aebb7add1853c759631be92d623ef67b5/src/globals/patch/php-src-patches/static_opcache_\(line).patch")!
        let patch = try await PHPBuildSupport.download(url: url, sha256: digest, maximumBytes: 32_000, root: root)
        try await command("/usr/bin/patch", ["--batch", "--forward", "-p1", "-i", patch.path], source: source, environment: environment, logs: logs, name: "static-opcache", timeout: 30)
        let notice = try await PHPBuildSupport.download(url: URL(string: "https://raw.githubusercontent.com/crazywhalecc/static-php-cli/c2b02e4aebb7add1853c759631be92d623ef67b5/LICENSE")!, sha256: "feb73706d9700944d2522ee064283e4cb96fe73a337125b9b3952952f15724d0", maximumBytes: 32_000, root: root)
        let destination = try GrovePaths.ensureDirectory(licenses.appendingPathComponent("StaticPHP"))
        try FileManager.default.copyItem(at: notice, to: destination.appendingPathComponent("LICENSE"))
        try FileManager.default.copyItem(at: patch, to: destination.appendingPathComponent("static-opcache.patch"))
    }

    private static func buildDebuggers(source php: URL, directory: URL, output: URL, root: URL, environment: [String: String], licenses: URL) async throws -> (xdebug: URL, spx: URL, assets: URL) {
        let xdebugArchive = try await PHPBuildSupport.download(url: URL(string: "https://xdebug.org/files/xdebug-\(InspectorXdebug.version).tgz")!, sha256: InspectorXdebug.archiveSHA256, maximumBytes: 8_000_000, root: root)
        let xdebugUnpack = directory.appendingPathComponent("sources/xdebug")
        try await PHPBuildSupport.extract(archive: xdebugArchive, to: xdebugUnpack)
        let xdebug = xdebugUnpack.appendingPathComponent("xdebug-\(InspectorXdebug.version)")
        try """
        #define HAVE_XDEBUG 1
        #define HAVE_XDEBUG_CLOCK_GETTIME 1
        #define HAVE_XDEBUG_CLOCK_GETTIME_NSEC_NP 1
        #define HAVE_GETTIMEOFDAY 1
        #define HAVE_NETINET_IN_H 1
        #define HAVE_POLL_H 1
        #define HAVE_SYS_POLL_H 1
        #define HAVE_RES_NINIT 1
        #define HAVE_RES_NCLOSE 1
        #define HAVE_XDEBUG_ZLIB 1
        #define COMPILE_DL_XDEBUG 1
        """.write(to: xdebug.appendingPathComponent("config.h"), atomically: true, encoding: .utf8)
        let includes = ["", "main", "Zend", "TSRM", "ext", "ext/date/lib"].map { "-I" + php.appendingPathComponent($0).path }
        let xdebugModule = output.appendingPathComponent("xdebug.so")
        try await command("/usr/bin/clang", ["-bundle", "-undefined", "dynamic_lookup", "-O2", "-fPIC", "-DHAVE_CONFIG_H", "-DZEND_ENABLE_STATIC_TSRMLS_CACHE=1"] + includes + ["-I" + xdebug.path, "-I" + xdebug.appendingPathComponent("src").path] + xdebugSources + ["-lz", "-lresolv", "-o", xdebugModule.path], source: xdebug, environment: environment, logs: directory, name: "xdebug", timeout: 300)
        let spxArchive = try await PHPBuildSupport.download(url: URL(string: "https://codeload.github.com/NoiseByNorthwest/php-spx/tar.gz/\(InspectorSPX.sourceCommit)")!, sha256: InspectorSPX.archiveSHA256, maximumBytes: 8_000_000, root: root)
        let spxUnpack = directory.appendingPathComponent("sources/spx")
        try await PHPBuildSupport.extract(archive: spxArchive, to: spxUnpack)
        let spx = spxUnpack.appendingPathComponent("php-spx-\(InspectorSPX.sourceCommit)")
        try "#define HAVE_SPX 1\n#define COMPILE_DL_SPX 1\n#define SPX_HTTP_UI_ASSETS_DIR \"/var/empty\"\n".write(to: spx.appendingPathComponent("config.h"), atomically: true, encoding: .utf8)
        let spxModule = output.appendingPathComponent("spx.so")
        try await command("/usr/bin/clang", ["-bundle", "-undefined", "dynamic_lookup", "-O3", "-fPIC", "-pthread", "-std=gnu90", "-Wno-typedef-redefinition", "-DHAVE_CONFIG_H", "-DZEND_ENABLE_STATIC_TSRMLS_CACHE=1"] + includes + ["-I" + spx.path, "-I" + spx.appendingPathComponent("src").path] + spxSources + ["-lz", "-o", spxModule.path], source: spx, environment: environment, logs: directory, name: "spx", timeout: 180)
        try copyNotices(from: xdebug, to: licenses.appendingPathComponent("Xdebug"))
        try copyNotices(from: spx, to: licenses.appendingPathComponent("SPX"))
        return (xdebugModule, spxModule, spx.appendingPathComponent("assets/web-ui"))
    }

    static func validate(runtime: RuntimeInstallation, php: URL, fpm: URL, modules: [String: URL], environment: [String: String]) async throws {
        let probe = """
        $curl = curl_version(); $features = [];
        foreach (['HTTP2','HTTP3','IDN','BROTLI','ZSTD','SSL','ASYNCHDNS','GSSAPI','KERBEROS5','SPNEGO','HTTPS_PROXY','UNIX_SOCKETS'] as $name) {
            $constant = 'CURL_VERSION_' . $name;
            $features[$name] = defined($constant) && (($curl['features'] & constant($constant)) !== 0);
        }
        echo json_encode(['version'=>PHP_VERSION,'modules'=>get_loaded_extensions(),'curlFeatures'=>$features,'curlProtocols'=>$curl['protocols']]);
        """
        let original = try await ProcessRunner.run(executable: runtime.executablePath, arguments: ["-n", "-r", probe], environment: environment, timeout: 15).requireSuccess()
        let replacement = try await ProcessRunner.run(executable: php.path, arguments: ["-n", "-r", probe], environment: environment, timeout: 15).requireSuccess()
        struct Inventory: Decodable { let version: String; let modules: [String]; let curlFeatures: [String: Bool]; let curlProtocols: [String] }
        let before = try JSONDecoder().decode(Inventory.self, from: Data(original.stdout.utf8))
        let after = try JSONDecoder().decode(Inventory.self, from: Data(replacement.stdout.utf8))
        guard original.stderr.isEmpty, replacement.stderr.isEmpty, before.version == runtime.version, after.version == runtime.version,
              Set(before.modules).isSubset(of: Set(after.modules)), Set(["mysqli", "Zend OPcache"]).isSubset(of: Set(after.modules)) else {
            throw GroveError.message("The prepared PHP runtime did not preserve the installed version and built-in extensions. The original runtime is unchanged.")
        }
        guard preservesCurlCapabilities(originalFeatures: before.curlFeatures, originalProtocols: before.curlProtocols,
                                        candidateFeatures: after.curlFeatures, candidateProtocols: after.curlProtocols) else {
            throw GroveError.message("The prepared PHP runtime did not preserve cURL's protocols and network features. The original runtime is unchanged.")
        }
        let fpmVersion = try await ProcessRunner.run(executable: fpm.path, arguments: ["-n", "-v"], environment: environment, timeout: 15).requireSuccess()
        guard fpmVersion.stderr.isEmpty, fpmVersion.stdout.hasPrefix("PHP \(runtime.version) (") else { throw GroveError.message("The prepared PHP-FPM version could not be verified.") }
        for file in [php, fpm] + modules.values.sorted(by: { $0.path < $1.path }) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 160_000_000 else { throw GroveError.message("A prepared PHP binary is invalid.") }
            try ManagedPHPInstaller.validateMachO(at: file, architecture: ManagedPHPCatalog.architecture, isExtension: file.pathExtension == "so")
        }
        for (name, module) in modules.sorted(by: { $0.key < $1.key }) {
            let directive = name == "xdebug" ? "zend_extension" : "extension"
            let args = ["-n", "-d", "\(directive)=\(module.path)"]
            let expectedVersion = name == "xdebug" ? InspectorXdebug.version : (name == "spx" ? InspectorSPX.version : runtime.version)
            let loaded = try await ProcessRunner.run(executable: php.path, arguments: args + ["-r", "echo phpversion('\(name)') ?: 'missing';"], environment: environment.merging(["XDEBUG_MODE": "off"]) { _, new in new }, timeout: 15).requireSuccess()
            let fpmLoaded = try await ProcessRunner.run(executable: fpm.path, arguments: args + ["-m"], environment: environment, timeout: 15).requireSuccess()
            guard loaded.stdout == expectedVersion, loaded.stderr.isEmpty, fpmLoaded.stderr.isEmpty,
                  fpmLoaded.stdout.split(separator: "\n").contains(where: { $0.lowercased() == name }) else { throw GroveError.message("\(name) could not load in both PHP and PHP-FPM. The original runtime is unchanged.") }
        }
    }

    /// Keep the installed runtime's protocols and supported network features.
    /// TLS-SRP is deliberately absent: upstream curl removed it in 8.22.
    static func preservesCurlCapabilities(originalFeatures: [String: Bool], originalProtocols: [String],
                                          candidateFeatures: [String: Bool], candidateProtocols: [String]) -> Bool {
        Set(originalProtocols).isSubset(of: Set(candidateProtocols))
            && originalFeatures.allSatisfy { name, enabled in !enabled || candidateFeatures[name] == true }
    }

    private static func copyNotices(from source: URL, to destination: URL) throws {
        let source = source.resolvingSymlinksInPath()
        _ = try GrovePaths.ensureDirectory(destination)
        guard let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for case let file as URL in files {
            let name = file.lastPathComponent.uppercased()
            guard name.hasPrefix("LICENSE") || name.hasPrefix("LICENCE") || name.hasPrefix("COPYING") || name.hasPrefix("NOTICE") || name == "COPYRIGHT" || name == "THIRD-PARTY-LICENSES.MD" else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let relative = String(file.path.dropFirst(source.path.count + 1))
            let target = destination.appendingPathComponent(relative)
            _ = try GrovePaths.ensureDirectory(target.deletingLastPathComponent())
            try FileManager.default.copyItem(at: file, to: target)
        }
    }

    private static func command(_ executable: String, _ arguments: [String], source: URL, environment: [String: String], logs: URL, name: String, timeout: TimeInterval) async throws {
        try Task.checkCancellation()
        let directory = try GrovePaths.ensureDirectory(logs.appendingPathComponent("logs"))
        let result: ProcessResult
        do {
            // Native hosted Intel runners can take longer than local Apple
            // Silicon even for configure. This path runs only on release hosts.
            let budget = ManagedPHPCatalog.architecture == "x86_64" ? timeout * 3 : timeout
            result = try await ProcessRunner.run(executable: executable, arguments: arguments, directory: source, environment: environment, timeout: budget, outputLimit: 4_000_000)
        } catch {
            try? PHPConfiguration.writePrivate(Data(error.localizedDescription.utf8), to: directory.appendingPathComponent(name + ".log"))
            throw GroveError.message("PHP preparation failed during \(name): \(error.localizedDescription)")
        }
        try PHPConfiguration.writePrivate(Data((result.stdout + "\n" + result.stderr).utf8), to: directory.appendingPathComponent(name + ".log"))
        guard result.exitCode == 0 else { throw GroveError.message("PHP preparation failed during \(name).\n" + String((result.stdout + "\n" + result.stderr).suffix(6_000))) }
    }
    private static let xdebugSources: [String] = [
        "xdebug.c",
        "src/base/base.c",
        "src/base/ctrl_socket.c",
        "src/base/filter.c",
        "src/lib/usefulstuff.c",
        "src/lib/cmd_parser.c",
        "src/lib/compat.c",
        "src/lib/crc32.c",
        "src/lib/file.c",
        "src/lib/hash.c",
        "src/lib/headers.c",
        "src/lib/lib.c",
        "src/lib/llist.c",
        "src/lib/log.c",
        "src/lib/normalize_path.c",
        "src/lib/set.c",
        "src/lib/str.c",
        "src/lib/stripcslashes.c",
        "src/lib/timing.c",
        "src/lib/trim.c",
        "src/lib/var.c",
        "src/lib/var_export_html.c",
        "src/lib/var_export_line.c",
        "src/lib/var_export_text.c",
        "src/lib/var_export_xml.c",
        "src/lib/xdebug_strndup.c",
        "src/lib/xml.c",
        "src/lib/maps/maps.c",
        "src/lib/maps/maps_private.c",
        "src/lib/maps/parser.c",
        "src/coverage/branch_info.c",
        "src/coverage/code_coverage.c",
        "src/debugger/com.c",
        "src/debugger/debugger.c",
        "src/debugger/handler_dbgp.c",
        "src/debugger/handlers.c",
        "src/debugger/ip_info.c",
        "src/develop/develop.c",
        "src/develop/monitor.c",
        "src/develop/php_functions.c",
        "src/develop/stack.c",
        "src/develop/superglobals.c",
        "src/gcstats/gc_stats.c",
        "src/profiler/profiler.c",
        "src/tracing/trace_computerized.c",
        "src/tracing/trace_flamegraph.c",
        "src/tracing/trace_html.c",
        "src/tracing/trace_textual.c",
        "src/tracing/tracing.c",
    ]
    private static let spxSources: [String] = [
        "src/php_spx.c",
        "src/spx_profiler.c",
        "src/spx_profiler_tracer.c",
        "src/spx_profiler_sampler.c",
        "src/spx_reporter_full.c",
        "src/spx_reporter_fp.c",
        "src/spx_reporter_trace.c",
        "src/spx_metric.c",
        "src/spx_resource_stats.c",
        "src/spx_hmap.c",
        "src/spx_str_builder.c",
        "src/spx_output_stream.c",
        "src/spx_php.c",
        "src/spx_stdio.c",
        "src/spx_config.c",
        "src/spx_utils.c",
        "src/spx_fmt.c",
    ]
}
