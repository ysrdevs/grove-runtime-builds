import Foundation

/// All dependencies live in the caller's private, space-free build directory.
/// Published GitHub asset digests are pinned; source archives are pinned to exact bytes.
enum ManagedPHPDependencyBuilder {
    struct Prepared: Sendable {
        let prefix: URL
        let environment: [String: String]
        let pkgConfig: String
    }
    static let hostedPackages: [(String, String, String)] = [
        ("bzip2", "be0d57cdf4752b857d42a670af7793629c1ef7a51f61020be8631b30b6985099", "45835de8a177f1d5e9c2d80a6e0aacd843a112ed6d9f702f2613439121127cb1"),
        ("brotli", "00aa21cc887c8e5acc222de09d95ea69f79b34f66bc776fd5b17f31305a37336", "5ec539d8e0a60d216c5f0e4e780d22f1dda498940d59e1213b58890edf4d3101"),
        ("gmp", "554438ee716a4032aee04287a704e48b1a4e23919757ff1454f411bb84786e8a", "4d5c53c358324b644d0a1845faf4b7732234fd5a223583a8cab4b7d39cfc66f7"),
        ("icu", "53c7675851fe00f383710267ba765b0883023bc350fca3d76bc1e529500599f5", "d01942a8d1862d97a6a31b6ba763d42d12054c1192d5402cde2191f5fa1a4ceb"),
        ("libiconv", "a5730f0b96f861ea92dd9df23785600bfc930239d59710c8fe50f67acb210a7f", "7d29c52a9920c21c68354df5a447ccc9ff3b531e62e184846d7f1edc885a2961"),
        ("libcares", "d36fa5f5cfbeb02f28c3ed44dc0d3a40246c7b7683b6a224ec7b7f55c597d653", "1a130fd3be9eb9b5acb2737c50da7d31bfa20e22671d832d81c8ce032b72e525"),
        ("liblz4", "cda06e8b903421500d27c8eecc08e68fc609d57890bda7c271e72f13903374ea", "aa461d1508aafa53324bb729bdc72d8f7cd165baa2d565d7b53cb88128d1165a"),
        ("libpng", "179ff2271af74aff070133702b3fb2aa6d357d2b0eafe2f55be80d3b10198742", "3e959066629e61b73f060d32270b20cb83de1e572dd48394df210092e5f76305"),
        ("libsodium", "2bc1def2b50424285bdddf7c7af5ce724357bd1c3baea492d11081cf67b71794", "489537f1ca3268b8f209e69de0b1536669ee718d9b982eba2fe69cc6380971a7"),
        ("libssh2", "54b585c760ff735224a24b7a88d7f12eea3e64631703b81a0b1da617cf93e602", "fd63486f2420a65d3b858d1e2121883426e4e0167ee26ce569ad806f30a6b5a4"),
        ("libwebp", "34574d2506c0ff36782e1a78bfe18429a4b6ef4645a2b364255e12dcb41ee7af", "7a31b9be9fae2c67317f42c3ee6924495c3f20d9965fa26e983399e9854262fd"),
        ("onig", "7130f36644c6a0329a6debd94dd20b0303b643daaeeca1594e9bc9786711013a", "318c30faf148f8bdcf557ab916800685ce7ad31e65d6aac067144a8d7495d665"),
        ("openssl", "de94d32f6a6f3f44274660d50571304855d37e542c7b79b92a375f62f7874d5f", "6736020048d50d00c509f11e31bd92040880f2535797fd8f1871accf5208217f"),
        ("pkg-config", "7541c2f775e6a535acb47c8bab0a60d4c4c13eb62d09df334b21fecedd71a21e", "06c2f33c89c113226b86fdcd559dfc3f3747b1c5bfc0fffab91a66e803456290"),
        ("sqlite", "6cf49206a049beaf39860870d477e586c503d326a7cf189ff1ec72a81226e822", "9437979cddb28b4ea834c89fa675c1cdb9d4135d4ca3c3c650f112b4358cd547"),
        ("zlib", "b769fca873f99ddf71803911a2dec8bff3d421fd90417fb99356f8717c46bac4", "f94c46c656172b951f17a9c21faa2fd0debfcf7dc4950bda8e899eb41537e694"),
        ("libaom", "94f0738efd28a38481877b234b00b3a2d5dd0e4d384665fa6d6bdd01b9201b73", "a0c05702f43ed43df29a5f07b1ee785b598283644c3e94ce56902edf0c7258ed")
    ]
    struct Package: Sendable {
        let name: String
        let url: String
        let digest: String
        let topDirectory: String
        let maximumBytes: Int
    }
    static let sourcePackages: [Package] = [
        .init(name: "cmake", url: "https://github.com/Kitware/CMake/releases/download/v4.4.4/cmake-4.4.4-macos-universal.tar.gz", digest: "4b7b73704b1db9b374e5c9ab8e17ac6148b817b6396ee75cd94a852cbac9d305", topDirectory: "cmake-4.4.4-macos-universal/CMake.app/Contents", maximumBytes: 90_000_000),
        .init(name: "jpeg", url: "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz", digest: "6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e", topDirectory: "libjpeg-turbo-3.2.0", maximumBytes: 10_000_000),
        .init(name: "zip", url: "https://github.com/nih-at/libzip/releases/download/v1.12.1/libzip-1.12.1.tar.xz", digest: "c40062022a1963c80573d48f6070792297cecd7c6bffe3aefcac0d8b9bee8913", topDirectory: "libzip-1.12.1", maximumBytes: 4_000_000),
        .init(name: "postgres", url: "https://ftp.postgresql.org/pub/source/v18.6/postgresql-18.6.tar.bz2", digest: "555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f", topDirectory: "postgresql-18.6", maximumBytes: 40_000_000),
        .init(name: "freetype", url: "https://download-mirror.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz", digest: "93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5", topDirectory: "freetype-2.15.0", maximumBytes: 8_000_000),
        .init(name: "zstd", url: "https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz", digest: "eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3", topDirectory: "zstd-1.5.7", maximumBytes: 8_000_000),
        .init(name: "avif", url: "https://codeload.github.com/AOMediaCodec/libavif/tar.gz/refs/tags/v1.3.0", digest: "0a545e953cc049bf5bcf4ee467306a2f113a75110edf59e61248873101cd26c1", topDirectory: "libavif-1.3.0", maximumBytes: 20_000_000),
        .init(name: "curl", url: "https://github.com/curl/curl/releases/download/curl-8_23_0/curl-8.23.0.tar.xz", digest: "8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5", topDirectory: "curl-8.23.0", maximumBytes: 8_000_000),
        .init(name: "nghttp2", url: "https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/nghttp2-1.70.0.tar.xz", digest: "e05cb1388eaca3830aded4ccf20044b6e1ac1a61411dcca11b0437c4285c8bc2", topDirectory: "nghttp2-1.70.0", maximumBytes: 4_000_000),
        .init(name: "nghttp3", url: "https://github.com/ngtcp2/nghttp3/releases/download/v1.18.0/nghttp3-1.18.0.tar.xz", digest: "aad782c23d3f01bd4bb52c8bac7a553b631ef8115fd1612703df6183449fef19", topDirectory: "nghttp3-1.18.0", maximumBytes: 4_000_000),
        .init(name: "ngtcp2", url: "https://github.com/ngtcp2/ngtcp2/releases/download/v1.25.0/ngtcp2-1.25.0.tar.xz", digest: "2a34d2484ba17847a5d11965704e9dd0fac4c6d8efc75ffe1ec7de66d8c6b6fb", topDirectory: "ngtcp2-1.25.0", maximumBytes: 4_000_000),
        .init(name: "unistring", url: "https://ftp.gnu.org/gnu/libunistring/libunistring-1.4.2.tar.xz", digest: "5b46e74377ed7409c5b75e7a96f95377b095623b689d8522620927964a41499c", topDirectory: "libunistring-1.4.2", maximumBytes: 8_000_000),
        .init(name: "idn", url: "https://ftp.gnu.org/gnu/libidn/libidn2-2.3.8.tar.gz", digest: "f557911bf6171621e1f72ff35f5b1825bb35b52ed45325dcdee931e5d3c0787a", topDirectory: "libidn2-2.3.8", maximumBytes: 4_000_000)
    ]

    static func prepare(directory: URL, root: URL, progress: @escaping @Sendable (String) async -> Void) async throws -> Prepared {
        guard directory.path.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw GroveError.message("The PHP build directory must not contain spaces.") }
        let prefix = try GrovePaths.ensureDirectory(directory.appendingPathComponent("prefix"))
        var environment = try await PHPBuildSupport.compilerEnvironment()
        for (name, arm, intel) in hostedPackages {
            await progress("Downloading PHP libraries: \(name)…")
            let archive = try await PHPBuildSupport.download(url: URL(string: "https://github.com/static-php/hosted/releases/download/2026.2.17/\(name)-\(ManagedPHPCatalog.architecture)-darwin.txz")!,
                sha256: ManagedPHPCatalog.architecture == "aarch64" ? arm : intel, maximumBytes: 80_000_000, root: root)
            let extracted = directory.appendingPathComponent("hosted-\(name)")
            try await PHPBuildSupport.extract(archive: archive, to: extracted)
            _ = try await ProcessRunner.run(executable: "/usr/bin/ditto", arguments: [extracted.appendingPathComponent("buildroot").path, prefix.path], environment: environment, timeout: 45).requireSuccess()
        }
        try ManagedPHPExtensionInstaller.relocateMetadata(in: prefix)
        let pkgConfig = prefix.appendingPathComponent("bin/pkg-config")
        let realPkgConfig = prefix.appendingPathComponent("bin/pkg-config-real")
        try FileManager.default.moveItem(at: pkgConfig, to: realPkgConfig)
        let quotedExecutable = "'" + realPkgConfig.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try Data("#!/bin/sh\nexec \(quotedExecutable) --static \"$@\"\n".utf8).write(to: pkgConfig)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pkgConfig.path)
        environment["PKG_CONFIG"] = pkgConfig.path
        environment["PKG_CONFIG_LIBDIR"] = prefix.appendingPathComponent("lib/pkgconfig").path
        environment["CPPFLAGS"] = "-I" + prefix.appendingPathComponent("include").path
        environment["LDFLAGS"] = "-L" + prefix.appendingPathComponent("lib").path
        var source: [String: URL] = [:]
        for package in sourcePackages {
            await progress("Downloading PHP build sources: \(package.name)…")
            let archive = try await PHPBuildSupport.download(url: URL(string: package.url)!, sha256: package.digest, maximumBytes: package.maximumBytes, root: root)
            let extracted = directory.appendingPathComponent("source-\(package.name)")
            try await PHPBuildSupport.extract(archive: archive, to: extracted)
            source[package.name] = extracted.appendingPathComponent(package.topDirectory)
        }
        let licenseFiles: [String: [String]] = ["jpeg": ["LICENSE.md"], "zip": ["LICENSE"], "avif": ["LICENSE"],
            "freetype": ["LICENSE.TXT", "docs/FTL.TXT", "docs/GPLv2.TXT"], "zstd": ["LICENSE", "COPYING"], "postgres": ["COPYRIGHT"],
            "curl": ["COPYING"], "nghttp2": ["COPYING"], "nghttp3": ["COPYING"], "ngtcp2": ["COPYING"],
            "unistring": ["COPYING", "COPYING.LIB"], "idn": ["COPYING", "COPYING.LESSERv3", "COPYINGv2", "COPYING.unicode"]]
        for (name, files) in licenseFiles {
            let destination = try GrovePaths.ensureDirectory(prefix.appendingPathComponent("source-licenses/\(name)"))
            for file in files {
                let original = source[name]!.appendingPathComponent(file)
                try FileManager.default.copyItem(at: original, to: destination.appendingPathComponent(original.lastPathComponent))
            }
        }
        let cmake = source["cmake"]!.appendingPathComponent("bin/cmake")
        let jobs = String(min(8, ProcessInfo.processInfo.activeProcessorCount))
        let cmakeArguments = ["-DCMAKE_INSTALL_PREFIX=\(prefix.path)", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_PREFIX_PATH=\(prefix.path)",
            "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local", "-DCMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH=OFF", "-DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF",
            "-DCMAKE_FIND_FRAMEWORK=NEVER", "-DPython3_EXECUTABLE=/usr/bin/python3",
            "-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF", "-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF", "-DCMAKE_MAKE_PROGRAM=/usr/bin/make",
            "-DCMAKE_C_COMPILER=/usr/bin/clang", "-DCMAKE_CXX_COMPILER=/usr/bin/clang++", "-DCMAKE_OSX_SYSROOT=\(environment["SDKROOT"]!)",
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0", "-DBUILD_SHARED_LIBS=OFF"]
        var commandNumber = 0
        func run(_ executable: String, _ arguments: [String], at working: URL, extra: [String: String] = [:]) async throws {
            commandNumber += 1
            let phase = arguments.first == "-S" ? "configure" : (arguments.first == "--build" ? "build" : (arguments.first == "--install" || arguments.contains("install") ? "install" : "compile"))
            let label = "\(working.lastPathComponent)-\(URL(fileURLWithPath: executable).lastPathComponent)-\(phase)"
            let logDirectory = try GrovePaths.ensureDirectory(directory.appendingPathComponent("logs"))
            let log = logDirectory.appendingPathComponent(String(format: "%03d", commandNumber) + "-" + label + ".log")
            let result: ProcessResult
            do {
                result = try await ProcessRunner.run(executable: executable, arguments: arguments, directory: working,
                    environment: environment.merging(extra) { _, value in value }, timeout: 600, outputLimit: 1_000_000)
            } catch {
                try? PHPConfiguration.writePrivate(Data("\(label): \(error.localizedDescription)\n".utf8), to: log)
                throw error
            }
            let output = result.stdout + "\n" + result.stderr
            try PHPConfiguration.writePrivate(Data(output.utf8), to: log)
            guard result.exitCode == 0 else { throw GroveError.message("PHP library preparation failed during \(label).\n" + String(output.suffix(6_000))) }
        }
        func buildCMake(_ name: String, arguments: [String]) async throws {
            await progress("Building PHP library: \(name)…")
            let build = directory.appendingPathComponent("build-\(name)")
            try await run(cmake.path, ["-S", source[name]!.path, "-B", build.path] + cmakeArguments + arguments, at: directory)
            try await run(cmake.path, ["--build", build.path, "-j", jobs], at: directory)
            try await run(cmake.path, ["--install", build.path], at: directory)
        }
        try await buildCMake("jpeg", arguments: ["-DENABLE_SHARED=OFF", "-DENABLE_STATIC=ON", "-DWITH_TURBOJPEG=OFF", "-DWITH_SIMD=OFF"])
        try await buildCMake("zip", arguments: ["-DENABLE_GNUTLS=OFF", "-DENABLE_MBEDTLS=OFF", "-DENABLE_OPENSSL=OFF", "-DENABLE_COMMONCRYPTO=ON",
            "-DENABLE_BZIP2=ON", "-DENABLE_LZMA=OFF", "-DENABLE_ZSTD=OFF", "-DBUILD_TOOLS=OFF", "-DBUILD_REGRESS=OFF", "-DBUILD_EXAMPLES=OFF", "-DBUILD_DOC=OFF",
            "-DZLIB_LIBRARY=\(prefix.path)/lib/libz.a", "-DZLIB_INCLUDE_DIR=\(prefix.path)/include", "-DBZIP2_LIBRARY_RELEASE=\(prefix.path)/lib/libbz2.a", "-DBZIP2_INCLUDE_DIR=\(prefix.path)/include"])
        try await buildCMake("avif", arguments: ["-DAVIF_CODEC_AOM=SYSTEM", "-DAVIF_LIBYUV=OFF", "-DAVIF_BUILD_APPS=OFF", "-DAVIF_BUILD_TESTS=OFF"])
        await progress("Building PHP library: FreeType…")
        let freeType = source["freetype"]!
        let freeTypeBuild = try GrovePaths.ensureDirectory(directory.appendingPathComponent("build-freetype"))
        // New SDKs expose HVF, which is unavailable on Grove's macOS 14 deployment target.
        let freeTypeEnvironment = ["ac_cv_header_hvf_Scaler_h": "no"]
        try await run(freeType.appendingPathComponent("configure").path, ["--prefix=\(prefix.path)", "--enable-static", "--disable-shared", "--with-harfbuzz=no", "--with-brotli=no", "--with-bzip2=yes", "--with-zlib=yes", "--with-png=yes"], at: freeTypeBuild, extra: freeTypeEnvironment)
        try await run("/usr/bin/make", ["-j", jobs], at: freeTypeBuild, extra: freeTypeEnvironment)
        try await run("/usr/bin/make", ["install"], at: freeTypeBuild, extra: freeTypeEnvironment)
        await progress("Building PHP library: Zstandard…")
        let zstd = source["zstd"]!.appendingPathComponent("lib")
        try await run("/usr/bin/make", ["-j", jobs, "libzstd.a"], at: zstd)
        try await run("/usr/bin/make", ["install-static", "install-includes", "install-pc", "PREFIX=\(prefix.path)"], at: zstd)
        // Preserve the downloaded runtime's HTTP/3, SSH, IDN and compression
        // capabilities; macOS's older system libcurl omits several of these.
        let httpArguments = ["-DBUILD_STATIC_LIBS=ON", "-DENABLE_LIB_ONLY=ON", "-DENABLE_STATIC_LIB=ON", "-DENABLE_SHARED_LIB=OFF", "-DENABLE_DOC=OFF", "-DBUILD_TESTING=OFF",
            "-DCMAKE_EXE_LINKER_FLAGS=-L\(prefix.path)/lib -lz"]
        try await buildCMake("nghttp2", arguments: httpArguments)
        try await buildCMake("nghttp3", arguments: httpArguments)
        try await buildCMake("ngtcp2", arguments: httpArguments + ["-DENABLE_OPENSSL=ON", "-DOPENSSL_ROOT_DIR=\(prefix.path)", "-DOPENSSL_USE_STATIC_LIBS=ON",
            "-DOPENSSL_INCLUDE_DIR=\(prefix.path)/include", "-DOPENSSL_SSL_LIBRARY=\(prefix.path)/lib/libssl.a", "-DOPENSSL_CRYPTO_LIBRARY=\(prefix.path)/lib/libcrypto.a"])
        for name in ["unistring", "idn"] {
            await progress("Building PHP library: \(name)…")
            // A distinct build tree also avoids GNUmakefile self-links when
            // Foundation and configure use /tmp versus /private/tmp aliases.
            let working = try GrovePaths.ensureDirectory(directory.appendingPathComponent("build-\(name)"))
            try await run(source[name]!.appendingPathComponent("configure").path, ["--prefix=\(prefix.path)", "--enable-static", "--disable-shared", "--disable-nls",
                "--with-libiconv-prefix=\(prefix.path)", "--with-libunistring-prefix=\(prefix.path)"], at: working)
            try await run("/usr/bin/make", ["-j", jobs], at: working)
            try await run("/usr/bin/make", ["install"], at: working)
        }
        await progress("Building PHP library: curl…")
        let curl = source["curl"]!
        let curlBuild = try GrovePaths.ensureDirectory(directory.appendingPathComponent("build-curl"))
        let curlLibraries = ["openssl", "nghttp2", "nghttp3", "ngtcp2", "libssh2", "brotli", "zstd", "libidn2", "zlib"]
        let curlEnvironment = ["LIBS": "-L\(prefix.path)/lib -lz -lresolv"]
        try await run(curl.appendingPathComponent("configure").path, ["--prefix=\(prefix.path)", "--enable-static", "--disable-shared", "--disable-docs", "--disable-manual", "--without-libpsl"]
            + curlLibraries.map { "--with-\($0)=\(prefix.path)" }
            + ["--enable-ares=\(prefix.path)", "--with-gssapi=\(environment["SDKROOT"]!)/usr", "--with-ca-bundle=/etc/ssl/cert.pem", "--without-ca-path"], at: curlBuild, extra: curlEnvironment)
        try await run("/usr/bin/make", ["-j", jobs], at: curlBuild, extra: curlEnvironment)
        try await run("/usr/bin/make", ["install"], at: curlBuild, extra: curlEnvironment)
        await progress("Building PHP library: PostgreSQL…")
        let postgres = source["postgres"]!
        let postgresBuild = try GrovePaths.ensureDirectory(directory.appendingPathComponent("build-postgres"))
        try await run(postgres.appendingPathComponent("configure").path, ["--prefix=\(prefix.path)", "--without-readline", "--without-icu", "--with-ssl=openssl", "--without-ldap", "--without-gssapi", "--without-lz4", "--without-zstd"], at: postgresBuild)
        // Build only the static client library; the server and shared client are unnecessary.
        try await run("/usr/bin/make", ["-C", "src/interfaces/libpq", "-j", jobs, "libpq.a", "install-lib-static", "install-lib-pc", "SHLIB_LINK=-lssl -lcrypto -lz -lm"], at: postgresBuild)
        for component in ["src/common", "src/port", "src/include", "src/bin/pg_config"] {
            let flags = ["-C", component, "LDFLAGS=-L\(prefix.path)/lib -lz"]
            try await run("/usr/bin/make", flags + ["-j", jobs], at: postgresBuild)
            try await run("/usr/bin/make", flags + ["install"], at: postgresBuild)
        }
        for header in ["libpq-fe.h", "libpq-events.h"] {
            try FileManager.default.copyItem(at: postgres.appendingPathComponent("src/interfaces/libpq/\(header)"), to: prefix.appendingPathComponent("include/\(header)"))
        }
        // libpq exposes encoding helpers from the PIC variants. PostgreSQL's
        // ordinary archive renames them for command-line tools' private use.
        let pqMetadata = prefix.appendingPathComponent("lib/pkgconfig/libpq.pc")
        let pqText = try String(contentsOf: pqMetadata, encoding: .utf8)
            .replacingOccurrences(of: "-lpgcommon ", with: "-lpgcommon_shlib ")
            .replacingOccurrences(of: "-lpgport ", with: "-lpgport_shlib ")
        try PHPConfiguration.writePrivate(Data(pqText.utf8), to: pqMetadata)
        // The PHP engine must not retain a dependency on this temporary build prefix.
        try removeDynamicLibraries(from: prefix)
        let sdk = environment["SDKROOT"]!
        for (name, flag) in [("CURL_CFLAGS", "--cflags"), ("CURL_LIBS", "--libs")] {
            environment[name] = try await ProcessRunner.run(executable: pkgConfig.path, arguments: [flag, "libcurl"], environment: environment, timeout: 15).requireSuccess().stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        environment["LIBXML_CFLAGS"] = "-I\(sdk)/usr/include/libxml2"; environment["LIBXML_LIBS"] = "-lxml2"
        environment["PGSQL_CFLAGS"] = "-I\(prefix.path)/include"
        environment["PGSQL_LIBS"] = try await ProcessRunner.run(executable: pkgConfig.path, arguments: ["--libs", "libpq"], environment: environment, timeout: 15).requireSuccess().stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        return Prepared(prefix: prefix, environment: environment, pkgConfig: pkgConfig.path)
    }

    private static func removeDynamicLibraries(from prefix: URL) throws {
        guard let files = FileManager.default.enumerator(at: prefix, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where file.pathExtension == "dylib" { try FileManager.default.removeItem(at: file) }
    }
}
