import Foundation

enum ManagedPHPExtensionSupport {
    static func fileDigests(in directory: URL) throws -> [String: String] {
        var result = [String: String](), total = 0, nodes = 0
        func visit(_ folder: URL, relative: String, depth: Int) throws {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true, depth < 12 else { throw GroveError.message("Invalid PHP extension cache folder.") }
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
                let path = relative + file.lastPathComponent
                if path == "receipt.json" { continue }
                nodes += 1
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard nodes <= 4096, values.isSymbolicLink != true else { throw GroveError.message("Invalid PHP extension cache contents.") }
                if values.isDirectory == true { try visit(file, relative: path + "/", depth: depth + 1) }
                else {
                    let size = values.fileSize ?? Int.max
                    guard values.isRegularFile == true, size >= 0, size <= 400_000_000 - total else { throw GroveError.message("The PHP extension cache exceeds its size limit.") }
                    total += size
                    result[path] = PHPBuildSupport.hash(try Data(contentsOf: file, options: .mappedIfSafe))
                }
            }
        }
        try visit(directory, relative: "", depth: 0)
        return result
    }

}
