import Foundation

/// Obtains exact-version optional modules from Grove’s verified prebuilt kit.
/// Build helpers below are used only by the separate release publisher.
enum ManagedPHPExtensionInstaller {
    static func prepareLibraries(directory: URL, root: URL, progress: @escaping @Sendable (String) async -> Void) async throws -> ManagedPHPDependencyBuilder.Prepared {
        try await ManagedPHPDependencyBuilder.prepare(directory: directory, root: root, progress: progress)
    }

    static func validateDependencies(_ output: String) throws {
        let dependencies = output.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces).components(separatedBy: " (compatibility version")[0] }
        guard !dependencies.isEmpty, dependencies.allSatisfy({ ($0.hasPrefix("/usr/lib/") || $0.hasPrefix("/System/Library/")) && !$0.split(separator: "/").contains("..") }) else {
            throw GroveError.message("The extension depends on libraries outside macOS. Its build was discarded.")
        }
    }

    /// Hosted StaticPHP archives use this literal relocation token in pkg-config
    /// and libtool files; never rewrite compiled libraries or execute metadata.
    static func relocateMetadata(in prefix: URL) throws {
        guard let files = FileManager.default.enumerator(at: prefix, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw GroveError.message("The extension's library archive is incomplete.")
        }
        for case let url as URL in files where ["pc", "la"].contains(url.pathExtension) {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if attributes.isSymbolicLink == true { continue }
            guard attributes.isRegularFile == true else { throw GroveError.message("The library archive contains invalid build metadata.") }
            let original = try PHPConfiguration.boundedData(url)
            guard let text = String(data: original, encoding: .utf8) else { throw GroveError.message("The library archive contains invalid build metadata.") }
            let relocated = text.replacingOccurrences(of: "@build_root_path@", with: prefix.path)
                .replacingOccurrences(of: "@build_lib_path@", with: prefix.appendingPathComponent("lib").path)
            try PHPConfiguration.writePrivate(Data(relocated.utf8), to: url)
        }
    }
}
