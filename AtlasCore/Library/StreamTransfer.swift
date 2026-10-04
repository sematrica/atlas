import Foundation

/// URLSession data delegate writes each received buffer on a serial IO queue.
/// A download task is deliberately not used: its temporary file may live on the internal disk.
final class StreamTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Headers: Sendable { let etag: String?; let modified: String? }
    private let destination: URL
    private let access: LibraryAccess
    private let expectedSize: Int64
    private let offset: Int64
    private let validator: String?
    private let onHeaders: @Sendable (Headers) async throws -> Void
    private let onProgress: @Sendable (Int64, Double) -> Void
    private let lock=NSLock()
    private var continuation: CheckedContinuation<Void,Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var cancelled=false
    private var failure: Error?
    private var file: FileHandle?
    private var written: Int64
    private var tick=Date()
    private var lastBytes: Int64
    private var lastValidation=Date.distantPast

    init(destination: URL, access: LibraryAccess, size: Int64, offset: Int64, validator: String?,
         onHeaders: @escaping @Sendable (Headers) async throws -> Void,
         onProgress: @escaping @Sendable (Int64,Double) -> Void) {
        self.destination=destination; self.access=access; expectedSize=size; self.offset=offset; self.validator=validator
        self.onHeaders=onHeaders; self.onProgress=onProgress; written=offset; lastBytes=offset
    }
    func run(url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing:CancellationError()); return }
                self.continuation=continuation
                let config=URLSessionConfiguration.ephemeral
                config.urlCache=nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest=60; config.timeoutIntervalForResource=7*24*60*60
                let queue=OperationQueue(); queue.maxConcurrentOperationCount=1; queue.qualityOfService = .utility
                let session=URLSession(configuration:config,delegate:self,delegateQueue:queue)
                self.session=session
                var request=URLRequest(url:url)
                request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
                if offset > 0 {
                    request.setValue("bytes=\(offset)-",forHTTPHeaderField:"Range")
                    if let validator { request.setValue(validator,forHTTPHeaderField:"If-Range") }
                }
                let task=session.dataTask(with:request); self.task=task
                lock.unlock(); task.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() { lock.lock(); cancelled=true; let task=task; lock.unlock(); task?.cancel() }
    static func validate(response: HTTPURLResponse, offset: Int64, expectedSize: Int64) throws {
        guard response.value(forHTTPHeaderField:"Content-Encoding").map({$0 == "identity"}) ?? true else { throw AtlasError.invalidResponse }
        if offset > 0 {
            guard response.statusCode == 206 else { throw AtlasError.resumeRejected }
            let contentRange=response.value(forHTTPHeaderField:"Content-Range") ?? ""
            let parts=contentRange.replacingOccurrences(of:"bytes ",with:"").split(separator:"/")
            guard parts.count == 2, Int64(parts[1]) == expectedSize else { throw AtlasError.resumeRejected }
            let bounds=parts[0].split(separator:"-")
            guard bounds.count == 2, Int64(bounds[0]) == offset, Int64(bounds[1]) == expectedSize-1 else { throw AtlasError.resumeRejected }
        } else {
            guard response.statusCode == 200 else { throw AtlasError.invalidResponse }
        }
        if response.expectedContentLength >= 0, response.expectedContentLength != expectedSize-offset { throw AtlasError.invalidResponse }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response=response as? HTTPURLResponse else { throw AtlasError.invalidResponse }
            try Self.validate(response:response,offset:offset,expectedSize:expectedSize)
            try access.validate()
            file=try FileHandle(forWritingTo:destination)
            let size=try file!.seekToEnd()
            guard size == UInt64(offset) else { throw AtlasError.incompleteDownload }
            let headers=Headers(etag:response.value(forHTTPHeaderField:"ETag"),modified:response.value(forHTTPHeaderField:"Last-Modified"))
            Task {
                do { try await onHeaders(headers); completionHandler(.allow) }
                catch { self.lock.withLock { self.failure=error }; completionHandler(.cancel) }
            }
        } catch { failure=error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard written + Int64(data.count) <= expectedSize else { throw AtlasError.invalidResponse }
            if Date().timeIntervalSince(lastValidation) >= 1 { try access.validate(); lastValidation=Date() }
            try file?.write(contentsOf:data); written += Int64(data.count)
            let elapsed=Date().timeIntervalSince(tick)
            if elapsed >= 1 {
                try file?.synchronize()
                onProgress(written,Double(written-lastBytes)/elapsed); lastBytes=written; tick=Date()
            }
        } catch { failure=error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var resultError=failure ?? error
        do { try file?.synchronize(); try file?.close() } catch { resultError=resultError ?? error }
        file=nil
        if resultError == nil && written != expectedSize { resultError=AtlasError.incompleteDownload }
        lock.lock(); let completion=continuation; continuation=nil; self.task=nil; self.session=nil; lock.unlock()
        if let resultError { completion?.resume(throwing:resultError) } else { completion?.resume() }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
