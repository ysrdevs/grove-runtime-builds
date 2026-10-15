import Foundation

/// Maintainer-only private libraries for PHP's additional built-in extensions.
/// Every library is static; release binaries may link only to macOS system dylibs.
enum ManagedPHPParityDependencies {
    static let sources: [ManagedPHPDependencyBuilder.Package] = [
        .init(name: "gettext", url: "https://ftp.gnu.org/gnu/gettext/gettext-0.26.tar.xz", digest: "d1fb86e260cfe7da6031f94d2e44c0da55903dbae0a2fa0fae78c91ae1b56f00", topDirectory: "gettext-0.26", maximumBytes: 15_000_000),
        .init(name: "imagemagick", url: "https://download.imagemagick.org/releases/ImageMagick-7.1.2-34.tar.xz", digest: "d9d826fec211d56efbb4343f19697d0cfb83b387c1d9ab11cf9c5770056c246c", topDirectory: "ImageMagick-7.1.2-34", maximumBytes: 15_000_000),
        .init(name: "ldap", url: "https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-2.6.15.tgz", digest: "bc91225dbfc50354033b1303bc91d1a7f6ddd1dc32fac950d79c28fe66d6bca8", topDirectory: "openldap-2.6.15", maximumBytes: 10_000_000),
        .init(name: "imap", url: "https://codeload.github.com/static-php/imap/tar.gz/be0998979923815fab48cd130675967427d56f70", digest: "cf3344083e5d9f21de7f3a6401dacfa23f719421f06c7a08ffcc8989c8410573", topDirectory: "imap-be0998979923815fab48cd130675967427d56f70", maximumBytes: 4_000_000),
        .init(name: "unixodbc", url: "https://www.unixodbc.org/unixODBC-2.3.14.tar.gz", digest: "4e2814de3e01fc30b0b9f75e83bb5aba91ab0384ee951286504bb70205524771", topDirectory: "unixODBC-2.3.14", maximumBytes: 4_000_000)
    ]

    /// Ship the complete source for the additional LGPL libraries alongside
    /// their notices. The public Grove builder supplies the relinking recipe.
    static func preserveSourceArchive(_ package: ManagedPHPDependencyBuilder.Package, archive: URL, prefix: URL) throws {
        guard ["gettext", "unixodbc"].contains(package.name) else { return }
        let directory = try GrovePaths.ensureDirectory(prefix.appendingPathComponent("source-licenses/sources"))
        let target = directory.appendingPathComponent(URL(string: package.url)!.lastPathComponent)
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: archive, to: target) }
    }

    static func systemEnvironment(sdk: String) -> [String: String] {
        ["FFI_CFLAGS": "-I\(sdk)/usr/include/ffi", "FFI_LIBS": "-lffi",
         "EDIT_CFLAGS": "-I\(sdk)/usr/include", "EDIT_LIBS": "-ledit",
         "XSL_CFLAGS": "-I\(sdk)/usr/include/libxml2", "XSL_LIBS": "-lxslt -lxml2",
         "EXSLT_CFLAGS": "-I\(sdk)/usr/include/libxml2", "EXSLT_LIBS": "-lexslt -lxslt -lxml2"]
    }

    static func prepare(sources: [String: URL], prefix: URL, directory: URL, environment: [String: String],
                        progress: @escaping @Sendable (String) async -> Void) async throws {
        let jobs = String(min(8, ProcessInfo.processInfo.activeProcessorCount))
        let logs = try GrovePaths.ensureDirectory(directory.appendingPathComponent("parity-logs"))
        var number = 0
        @discardableResult func run(_ executable: String, _ arguments: [String], at working: URL,
                                   extra: [String: String] = [:], allowFailure: Bool = false) async throws -> ProcessResult {
            number += 1
            let label = "\(number)-\(working.lastPathComponent)-\(URL(fileURLWithPath: executable).lastPathComponent)"
            let result = try await ProcessRunner.run(executable: executable, arguments: arguments, directory: working,
                environment: environment.merging(extra) { _, value in value }, timeout: 1_800, outputLimit: 1_000_000)
            let output = result.stdout + "\n" + result.stderr
            try PHPConfiguration.writePrivate(Data(output.utf8), to: logs.appendingPathComponent(label + ".log"))
            guard result.exitCode == 0 || allowFailure else {
                throw GroveError.message("PHP library preparation failed during \(label).\n" + String(output.suffix(6_000)))
            }
            return result
        }
        let notices: [String: [String]] = ["gettext": ["gettext-runtime/intl/COPYING.LIB"], "imagemagick": ["LICENSE", "NOTICE"],
            "ldap": ["LICENSE", "COPYRIGHT"], "imap": ["LICENSE", "LICENSE.txt", "NOTICE"],
            "unixodbc": ["COPYING", "libltdl/COPYING.LIB"]]
        for (name, files) in notices {
            let destination = try GrovePaths.ensureDirectory(prefix.appendingPathComponent("source-licenses/\(name)"))
            for relative in files {
                let original = sources[name]!.appendingPathComponent(relative)
                let target = destination.appendingPathComponent(original.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: original, to: target) }
            }
        }
        let basic = ["--prefix=\(prefix.path)", "--enable-static", "--disable-shared"]
        await progress("Building PHP library: gettext…")
        let gettext = try GrovePaths.ensureDirectory(directory.appendingPathComponent("build-gettext"))
        try await run(sources["gettext"]!.appendingPathComponent("configure").path, basic +
            ["--disable-java", "--disable-c++", "--disable-d", "--disable-modula2", "--disable-rpath", "--disable-libasprintf", "--disable-openmp",
             "--with-included-libintl", "--with-libiconv-prefix=\(prefix.path)"], at: gettext)
        let intl = gettext.appendingPathComponent("gettext-runtime/intl")
        try await run("/usr/bin/make", ["-j", jobs], at: intl)
        try await run("/usr/bin/make", ["install"], at: intl)

        await progress("Building PHP library: unixODBC…")
        let odbc = try GrovePaths.ensureDirectory(directory.appendingPathComponent("build-unixodbc"))
        try await run(sources["unixodbc"]!.appendingPathComponent("configure").path, basic +
            ["--sysconfdir=/etc", "--disable-gui", "--disable-drivers", "--disable-driver-config",
             "--disable-readline", "--disable-editline", "--with-included-ltdl", "--with-libiconv-prefix=\(prefix.path)"], at: odbc)
        try await run("/usr/bin/make", ["-j", jobs], at: odbc)
        // Keep upstream's empty configuration-file install hook in the private
        // prefix. The compiled manager still reads /etc at runtime.
        try await run("/usr/bin/make", ["install", "sysconfdir=\(prefix.path)/etc"], at: odbc)
        // libltdl objects are already embedded in libodbc.a. Upstream's private
        // pkg-config flags otherwise point at an unavailable temporary .la file.
        let odbcMetadata = prefix.appendingPathComponent("lib/pkgconfig/odbc.pc")
        let odbcText = try String(contentsOf: odbcMetadata, encoding: .utf8)
        try odbcText.replacingOccurrences(of: "$(top_build_prefix)libltdl/libltdlc.la", with: "")
            .write(to: odbcMetadata, atomically: true, encoding: .utf8)

        await progress("Building PHP library: OpenLDAP…")
        let ldap = try GrovePaths.ensureDirectory(directory.appendingPathComponent("build-ldap"))
        let ldapEnvironment = ["LIBS": "-L\(prefix.path)/lib -lssl -lcrypto -lz -liconv"]
        try await run(sources["ldap"]!.appendingPathComponent("configure").path, basic +
            ["--disable-slapd", "--without-systemd", "--without-cyrus-sasl", "--with-tls=openssl", "ac_cv_func_pthread_kill_other_threads_np=no"], at: ldap, extra: ldapEnvironment)
        try await run("/usr/bin/make", ["depend"], at: ldap, extra: ldapEnvironment)
        for component in ["include", "libraries"] {
            try await run("/usr/bin/make", ["-C", component, "-j", jobs], at: ldap, extra: ldapEnvironment)
            try await run("/usr/bin/make", ["-C", component, "install"], at: ldap, extra: ldapEnvironment)
        }

        await progress("Building PHP library: IMAP…")
        let imap = sources["imap"]!, sdk = environment["SDKROOT"]!
        let imapMakefile = imap.appendingPathComponent("Makefile")
        let imapMake = try String(contentsOf: imapMakefile, encoding: .utf8)
        try imapMake.replacingOccurrences(of: "SSLINCLUDE=/usr/include/openssl", with: "SSLINCLUDE=\(prefix.path)/include")
            .replacingOccurrences(of: "SSLLIB=/usr/lib", with: "SSLLIB=\(prefix.path)/lib")
            .write(to: imapMakefile, atomically: true, encoding: .utf8)
        try Data().write(to: imap.appendingPathComponent("ip6"))
        for relative in ["tools/an", "tools/ua", "src/osdep/unix/drivers", "src/osdep/unix/mkauths"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imap.appendingPathComponent(relative).path)
        }
        // UW c-client predates modern Clang and needs explicit system includes.
        // Build only its static client; no IMAP daemon or command-line tool ships.
        let flags = "\(environment["CFLAGS"] ?? "-O2") -fPIC -Wno-implicit-function-declaration -Wno-incompatible-function-pointer-types -include \(sdk)/usr/include/poll.h -include \(sdk)/usr/include/time.h -include \(sdk)/usr/include/utime.h"
        let result = try await run("/usr/bin/make", ["osx", "CC=/usr/bin/clang", "SPECIALAUTHENTICATORS=ssl", "SSLTYPE=unix.nopwd",
            "SSLINCLUDE=\(prefix.path)/include", "SSLLIB=\(prefix.path)/lib", "EXTRACFLAGS=\(flags)", "EXTRALDFLAGS=-lz"], at: imap, allowFailure: true)
        let client = imap.appendingPathComponent("c-client/c-client.a")
        guard FileManager.default.fileExists(atPath: client.path) else {
            throw GroveError.message("The IMAP client library could not be built.\n" + String((result.stdout + result.stderr).suffix(6_000)))
        }
        try FileManager.default.copyItem(at: client, to: prefix.appendingPathComponent("lib/libc-client.a"))
        let headers = try GrovePaths.ensureDirectory(prefix.appendingPathComponent("include/c-client"))
        for location in [imap.appendingPathComponent("c-client"), imap.appendingPathComponent("src/osdep/unix")] {
            for file in try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil) where file.pathExtension == "h" {
                let target = headers.appendingPathComponent(file.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: file, to: target) }
            }
        }

        await progress("Building PHP library: ImageMagick…")
        let magick = try GrovePaths.ensureDirectory(directory.appendingPathComponent("build-imagemagick"))
        let supported = ["bzlib", "freetype", "jpeg", "png", "webp", "zlib", "zstd"]
        let excluded = ["x", "gslib", "dps", "fftw", "flif", "fpx", "djvu", "heic", "jbig", "jxl", "lcms", "lqr", "lzma", "openexr", "openjp2", "pango", "raqm", "raw", "rsvg", "tiff", "wmf", "xml", "zip"]
        try await run(sources["imagemagick"]!.appendingPathComponent("configure").path, basic +
            ["--disable-openmp", "--without-gcc-arch", "--without-modules", "--without-magick-plus-plus", "--without-perl", "--with-utilities=no", "--enable-zero-configuration"] +
            supported.map { "--with-\($0)=yes" } + excluded.map { "--without-\($0)" }, at: magick,
            extra: ["LIBS": "-L\(prefix.path)/lib -liconv", "FONTCONFIG_CFLAGS": "", "FONTCONFIG_LIBS": ""])
        try await run("/usr/bin/make", ["-j", jobs], at: magick)
        try await run("/usr/bin/make", ["install"], at: magick)
        // cURL was prepared before OpenLDAP. Its macOS LDAP flag now resolves
        // to our private static archive, which also needs the BER library.
        let curlMetadata = prefix.appendingPathComponent("lib/pkgconfig/libcurl.pc")
        let curlText = try String(contentsOf: curlMetadata, encoding: .utf8)
        try curlText.replacingOccurrences(of: #"-lldap(?=\s|$)"#, with: "-lldap -llber", options: .regularExpression)
            .write(to: curlMetadata, atomically: true, encoding: .utf8)
    }
}
