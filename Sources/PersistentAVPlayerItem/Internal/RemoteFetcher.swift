// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

/// Receives the callbacks of one data task. Called on `IO.queue`.
protocol RemoteDataTaskHandler: AnyObject {
    /// Return `false` to cancel the task.
    func remoteTask(_ task: URLSessionTask, didReceive response: URLResponse) -> Bool
    func remoteTask(_ task: URLSessionTask, didReceive data: Data)
    func remoteTask(_ task: URLSessionTask, didCompleteWithError error: Error?)
}

/// A `URLSession` whose delegate callbacks run on `IO.queue` and are routed to
/// per-task handlers. The handler is retained until its task completes.
final class RemoteFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession!
    private var handlers: [Int: RemoteDataTaskHandler] = [:]

    init(configuration: URLSessionConfiguration) {
        super.init()
        let configuration = configuration.copy() as! URLSessionConfiguration
        // Bytes are cached on disk by this library; URLCache would hold a second copy.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Many tiles on one page usually come from the same CDN host.
        configuration.httpMaximumConnectionsPerHost = max(configuration.httpMaximumConnectionsPerHost, 16)

        let delegateQueue = OperationQueue()
        delegateQueue.name = "PersistentAVPlayerItem.network"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = IO.queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    /// Must be called on `IO.queue`.
    func startTask(with request: URLRequest, handler: RemoteDataTaskHandler) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        handlers[task.taskIdentifier] = handler
        task.resume()
        return task
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let handler = handlers[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        completionHandler(handler.remoteTask(dataTask, didReceive: response) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handlers[dataTask.taskIdentifier]?.remoteTask(dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        handlers.removeValue(forKey: task.taskIdentifier)?.remoteTask(task, didCompleteWithError: error)
    }
}
