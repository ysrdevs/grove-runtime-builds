import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    @discardableResult public func requireSuccess() throws -> ProcessResult {
        guard exitCode == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GroveError.message(detail.isEmpty ? "The command exited with status \(exitCode)." : String(detail.suffix(6_000)))
        }
        return self
    }
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let event = DispatchSemaphore(value: 0)
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); wake() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func wake() { event.signal() }
    func wait(until deadline: DispatchTime) -> DispatchTimeoutResult { event.wait(timeout: deadline) }
}

private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    init(limit: Int = 2_000_000) { self.limit = limit }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data.removeFirst(data.count - limit) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

private final class ProcessPipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private let output: ProcessOutput
    private var finished = false
    init(handle: FileHandle, output: ProcessOutput) {
        descriptor = handle.fileDescriptor; self.output = output
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }
    func drain(finish: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            output.append(Data(buffer.prefix(count)))
        }
        finished = finish
    }
}

enum OwnedCommandChildren {
    struct Identity {
        let pid: pid_t
        let seconds: Int
        let microseconds: Int32
        init(_ process: kinfo_proc) {
            pid = process.kp_proc.p_pid
            seconds = process.kp_proc.p_starttime.tv_sec
            microseconds = process.kp_proc.p_starttime.tv_usec
        }
        var isAlive: Bool {
            var process = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
            var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&query, u_int(query.count), &process, &size, nil, 0) == 0, size > 0 else { return false }
            return process.kp_proc.p_starttime.tv_sec == seconds && process.kp_proc.p_starttime.tv_usec == microseconds
                && process.kp_proc.p_stat != Int8(SZOMB)
        }
        func signal(_ value: Int32) { if isAlive { kill(pid, value) } }
    }
    static func snapshot(of parent: pid_t) -> [Identity] {
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL], size = 0
        guard sysctl(&query, u_int(query.count), nil, &size, nil, 0) == 0 else { return [] }
        // Allow the table to grow between size and data queries.
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 64)
        size = table.count * MemoryLayout<kinfo_proc>.stride
        let result = table.withUnsafeMutableBytes { sysctl(&query, u_int(query.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return [] }
        let processes = Array(table.prefix(size / MemoryLayout<kinfo_proc>.stride))
        var parents: Set<pid_t> = [parent], children: [Identity] = []
        for _ in 0..<32 {
            let next = processes.filter { parents.contains($0.kp_eproc.e_ppid) && !parents.contains($0.kp_proc.p_pid) }
            if next.isEmpty { break }
            children += next.map(Identity.init)
            parents.formUnion(next.map { $0.kp_proc.p_pid })
        }
        return children
    }
}

public enum ProcessRunner {
    /// Executes an argument vector directly. Output is bounded and cancellation stops the owned process.
    public static func run(executable: String, arguments: [String], directory: URL? = nil,
                           environment: [String: String] = [:], removingEnvironment: Set<String> = [], timeout: TimeInterval = 120, outputLimit: Int = 2_000_000, standardInput: Data? = nil) async throws -> ProcessResult {
        guard (standardInput?.count ?? 0) <= 8_192 else { throw GroveError.message("Command input exceeds the 8 KB limit.") }
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    // Wake immediately on exit or cancellation; polling imposed a 25 ms floor
                    // on every short command and kept long-lived commands waking while idle.
                    process.terminationHandler = { _ in cancellation.wake() }
                    defer { process.terminationHandler = nil }
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.currentDirectoryURL = directory
                    var inherited = GrovePaths.processEnvironment
                    for key in removingEnvironment { inherited.removeValue(forKey: key) }
                    process.environment = inherited.merging(environment) { _, new in new }
                    let input = standardInput == nil ? nil : Pipe()
                    if let input {
                        process.standardInput = input
                        // A child may close stdin immediately; do not deliver SIGPIPE to Grove.
                        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    } else { process.standardInput = FileHandle.nullDevice }
                    defer {
                        try? input?.fileHandleForReading.close()
                        try? input?.fileHandleForWriting.close()
                    }
                    let stdout = Pipe(), stderr = Pipe()
                    let limit = min(32_000_000, max(1_000, outputLimit))
                    let out = ProcessOutput(limit: limit), err = ProcessOutput(limit: limit)
                    process.standardOutput = stdout; process.standardError = stderr
                    let outReader = ProcessPipeReader(handle: stdout.fileHandleForReading, output: out)
                    let errReader = ProcessPipeReader(handle: stderr.fileHandleForReading, output: err)
                    stdout.fileHandleForReading.readabilityHandler = { _ in outReader.drain() }
                    stderr.fileHandleForReading.readabilityHandler = { _ in errReader.drain() }
                    do {
                        if cancellation.isCancelled { throw CancellationError() }
                        try process.run()
                        if let input, let standardInput {
                            try? input.fileHandleForReading.close()
                            // This bounded payload fits in a pipe; no stdin writer thread can outlive cancellation.
                            try? input.fileHandleForWriting.write(contentsOf: standardInput)
                            try? input.fileHandleForWriting.close()
                        }
                        let deadline = DispatchTime.now() + max(0.05, timeout)
                        var timedOut = false
                        while process.isRunning {
                            if cancellation.isCancelled || DispatchTime.now() >= deadline {
                                timedOut = !cancellation.isCancelled
                                // Installers may own curl/compiler children. Remember kernel start times
                                // before termination so a reused PID can never target an unrelated process.
                                let children = OwnedCommandChildren.snapshot(of: process.processIdentifier)
                                for child in children.reversed() { child.signal(SIGTERM) }
                                process.terminate()
                                let stopDeadline = Date().addingTimeInterval(2)
                                while (process.isRunning || children.contains(where: { $0.isAlive })) && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.025) }
                                for child in children.reversed() { child.signal(SIGKILL) }
                                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                                break
                            }
                            _ = cancellation.wait(until: deadline)
                        }
                        process.waitUntilExit()
                        stdout.fileHandleForReading.readabilityHandler = nil
                        stderr.fileHandleForReading.readabilityHandler = nil
                        // Do not wait for EOF: a spawned child may have inherited the pipe after its parent exits.
                        outReader.drain(finish: true); errReader.drain(finish: true)
                        if cancellation.isCancelled { throw CancellationError() }
                        if timedOut { throw GroveError.message("The command took longer than \(Int(timeout)) seconds and was stopped.") }
                        continuation.resume(returning: ProcessResult(exitCode: process.terminationStatus, stdout: out.text, stderr: err.text))
                    } catch {
                        stdout.fileHandleForReading.readabilityHandler = nil
                        stderr.fileHandleForReading.readabilityHandler = nil
                        outReader.drain(finish: true); errReader.drain(finish: true)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}
