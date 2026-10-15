import Foundation
import Darwin
import GroveCore

@main struct GrovePHPReleaseCommand {
    static func main() async {
        setbuf(stdout, nil)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first, ["build", "import-cache", "verify"].contains(command) else {
                print("""
                Maintainer tooling. Never shipped to or executed by Grove users.
                grove-php-release build --version 8.4.26 --workspace /private/tmp/grove-build --output /path/payload [--baseline /path/php]
                grove-php-release import-cache --version 8.4.26 --cache /path/cache --output /path/payload --baseline /path/php
                grove-php-release verify --version 8.4.26 --output /path/payload --baseline /path/php
                """)
                return
            }
            var options = [String: String]()
            let rest = Array(args.dropFirst())
            guard rest.count.isMultiple(of: 2) else { throw Failure("Arguments must be --name value pairs.") }
            for index in stride(from: 0, to: rest.count, by: 2) {
                let key = rest[index]
                guard ["--version", "--workspace", "--output", "--baseline", "--cache"].contains(key), options[key] == nil else { throw Failure("Unknown or duplicate argument: \(key)") }
                options[key] = rest[index + 1]
            }
            func required(_ name: String) throws -> String { guard let value = options[name] else { throw Failure("Missing \(name)") }; return value }
            func url(_ name: String) throws -> URL { let value = try required(name); guard value.hasPrefix("/") else { throw Failure("\(name) must be an absolute path.") }; return URL(fileURLWithPath: value) }
            let version = try required("--version"), output = try url("--output")
            if command == "build" {
                try await ManagedPHPRelease.build(version: version, workspace: try url("--workspace"), output: output,
                    baseline: options["--baseline"].map { URL(fileURLWithPath: $0) }) { print($0) }
            } else if command == "import-cache" {
                try await ManagedPHPRelease.importCache(try url("--cache"), version: version, output: output, baseline: try url("--baseline"))
            } else { try await ManagedPHPRelease.verify(directory: output, version: version, baseline: try url("--baseline")) }
            print("Verified PHP \(version) \(ManagedPHPRelease.architecture): CLI/FPM, all modules, intl/sodium operations, Xdebug/SPX captures, FPM startup.")
        } catch {
            FileHandle.standardError.write(Data("Release failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    struct Failure: LocalizedError { let errorDescription: String?; init(_ message: String) { errorDescription = message } }
}
