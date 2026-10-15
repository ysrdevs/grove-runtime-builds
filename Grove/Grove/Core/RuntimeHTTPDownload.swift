import Foundation

/// Bounded, cancellable HTTPS transfers shared by runtime and extension installers.
final class RuntimeHTTPDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let acceptsURL: @Sendable (URL) -> Bool
    private let limit: Int
    private let progress: (@Sendable (Int) -> Void)?
    private var lastProgress = Date.distantPast
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var finished = false

    private init(limit: Int, acceptsURL: @escaping @Sendable (URL) -> Bool, progress: (@Sendable (Int) -> Void)?) {
        self.acceptsURL = acceptsURL
        self.limit = limit
        self.progress = progress
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(acceptsURL) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url.map(acceptsURL) == true, response.expectedContentLength <= limit else {
            completionHandler(.cancel)
            finish(.failure(GroveError.message("The PHP download server returned an unexpected response. Try Check for Updates again.")))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= limit - buffer.count else {
            lock.unlock()
            finish(.failure(GroveError.message("The PHP download exceeds its size limit.")))
            return
        }
        buffer.append(data)
        let received = buffer.count, now = Date()
        let report = now.timeIntervalSince(lastProgress) >= 0.15
        if report { lastProgress = now }
        lock.unlock()
        if report { progress?(received) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let result = buffer
        lock.unlock()
        finish(.success(result))
    }

    private func start(_ url: URL, configuration: URLSessionConfiguration,
                       continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        // Cancellation may arrive before the continuation has been registered.
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        let queue = OperationQueue()
        queue.name = "Grove verified download"
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: url)
        self.continuation = continuation
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let session = self.session
        let task = self.task
        self.continuation = nil
        self.session = nil
        self.task = nil
        buffer = Data()
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    static func data(_ url: URL, limit: Int, configuration suppliedConfiguration: URLSessionConfiguration? = nil, progress: (@Sendable (Int) -> Void)? = nil, acceptsURL: @escaping @Sendable (URL) -> Bool) async throws -> Data {
        guard acceptsURL(url) else { throw GroveError.message("PHP downloads must come from the trusted upstream.") }
        guard limit > 0 else { throw GroveError.message("The PHP download size limit is invalid.") }
        try Task.checkCancellation()
        let delegate = RuntimeHTTPDownload(limit: limit, acceptsURL: acceptsURL, progress: progress)
        let configuration = suppliedConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        // URLSession delivers whole chunks on its own queue. An AsyncBytes loop
        // performs millions of per-byte awaits and can inherit the UI executor
        // with approachable concurrency, delaying both redraws and cancellation.
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(url, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            delegate.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return data
    }
}
