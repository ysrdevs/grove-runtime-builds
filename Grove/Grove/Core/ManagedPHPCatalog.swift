import Foundation

/// StaticPHP's maintained, standalone CLI/FPM builds. Only complete native pairs
/// are offered; a catalog entry never supplies an arbitrary executable URL.
enum ManagedPHPCatalog {
    static let baseURL = URL(string: "https://dl.static-php.dev/v3/php-bin/common/")!
    static let indexURL = URL(string: "https://dl.static-php.dev/v3/php-bin/common/?format=json")!
    static var architecture: String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "x86_64"
        #endif
    }
    struct Entry: Decodable {
        let name: String
        let full_path: String
        let is_dir: Bool
    }
    struct Package: Equatable, Sendable {
        let version: String
        let architecture: String
        var identifier: String { "staticphp-\(version)-\(architecture)" }
        var release: RuntimeRelease {
            .init(family: .php, version: version, label: "Grove · PHP \(version.split(separator: ".").prefix(2).joined(separator: "."))", installIdentifier: identifier)
        }
        func archiveName(sapi: String) -> String { "php-\(version)-\(sapi)-macos-\(architecture).tar.gz" }
        func url(sapi: String) -> URL { baseURL.appendingPathComponent(archiveName(sapi: sapi)) }
    }
    static func packages(data: Data, architecture: String = architecture) throws -> [Package] {
        guard ["aarch64", "x86_64"].contains(architecture), data.count <= 4_000_000 else { throw GroveError.message("The PHP download catalog is invalid.") }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard entries.count <= 20_000 else { throw GroveError.message("The PHP download catalog is too large.") }
        var variants = [String: Set<String>]()
        let pattern = #"^php-(8\.[2-9][0-9]*\.[0-9]+)-(cli|fpm)-macos-"# + architecture + #"\.tar\.gz$"#
        let regex = try NSRegularExpression(pattern: pattern)
        for entry in entries where !entry.is_dir && entry.full_path == "/v3/php-bin/common/" + entry.name {
            guard let match = regex.firstMatch(in: entry.name, range: NSRange(entry.name.startIndex..., in: entry.name)),
                  let versionRange = Range(match.range(at: 1), in: entry.name), let sapiRange = Range(match.range(at: 2), in: entry.name) else { continue }
            variants[String(entry.name[versionRange]), default: []].insert(String(entry.name[sapiRange]))
        }
        return variants.filter { $0.value == ["cli", "fpm"] }
            .map { Package(version: $0.key, architecture: architecture) }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }
    static func latestReleases(_ packages: [Package]) -> [RuntimeRelease] {
        var lines = Set<String>()
        return packages.filter { lines.insert($0.version.split(separator: ".").prefix(2).joined(separator: ".")).inserted }.map(\.release)
    }
    static func validIdentifier(_ value: String, version: String) -> Bool {
        version.range(of: #"^8\.[2-9][0-9]*\.[0-9]+$"#, options: .regularExpression) != nil
            && value == Package(version: version, architecture: architecture).identifier
    }

}

/// TLS is the upstream's authenticity mechanism. The upstream does not publish
/// archive digests; installation receipts record local SHA-256 for diagnostics,
/// not as an independent signature or published checksum verification.
enum ManagedPHPDownload {
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        if url.host == "dl.static-php.dev" {
            if url.path == "/down", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let query = parts.queryItems, query.count == 1, query[0].name == "path", let path = query[0].value {
                let normalized = path.hasPrefix("/") ? path : "/" + path
                return normalized.hasPrefix("/v3/php-bin/common/") && !normalized.contains("..")
            }
            return (url.path == "/v3/php-bin/common" || url.path.hasPrefix("/v3/php-bin/common/")) && !url.path.contains("..")
        }
        return url.host == "static-php-cli.fra1.digitaloceanspaces.com"
            && url.path.hasPrefix("/v3/php-bin/common/") && !url.path.contains("..")
    }
    static func data(_ url: URL, limit: Int, configuration: URLSessionConfiguration? = nil) async throws -> Data {
        try await RuntimeHTTPDownload.data(url, limit: limit, configuration: configuration, acceptsURL: allowed)
    }
}
