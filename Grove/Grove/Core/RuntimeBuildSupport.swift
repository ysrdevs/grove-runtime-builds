import Foundation

public enum GroveError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public enum RuntimeFamily: String, Codable, Sendable { case php }
public struct RuntimeInstallation: Sendable {
    public let family: RuntimeFamily
    public let version: String
    public let executablePath: String
    public let source: String
    public init(family: RuntimeFamily, version: String, executablePath: String, source: String) {
        self.family = family; self.version = version; self.executablePath = executablePath; self.source = source
    }
}
struct RuntimeRelease { let family: RuntimeFamily; let version: String; let label: String; let installIdentifier: String }
enum GrovePaths {
    static var processEnvironment: [String: String] { ProcessInfo.processInfo.environment }
    static func ensureDirectory(_ directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
}
enum PHPConfiguration {
    static func boundedData(_ file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2_000_000 else { throw GroveError.message("Invalid bounded metadata file") }
        return try Data(contentsOf: file)
    }
    static func writePrivate(_ bytes: Data, to file: URL) throws {
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
enum InspectorXdebug {
    static let version = "3.5.3"
    static let archiveSHA256 = "f073de91bea046106abf4d6071c963ea71e58571df6ce58948ceca89d121cb2d"
}
enum InspectorSPX {
    static let version = "0.4.22"
    static let archiveSHA256 = "cd8f7cdd4174e167409a86c61c5744e54539c49c2450f5f1f1aba3c76fe2d4e7"
    static let sourceCommit = "625fa8542415ff9cd3380432989b1cd139e1d346"
}
