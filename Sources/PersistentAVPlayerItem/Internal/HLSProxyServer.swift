// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation
import Network

/// A small HTTP server on 127.0.0.1 that plays HLS streams through the cache.
///
/// A resource loader may answer AVFoundation's requests for HLS playlists, but
/// not for media segments, so HLS items play `http://127.0.0.1:<port>/…` instead.
/// The server fetches each playlist (or reads it from the cache) and rewrites its
/// URIs so that variant playlists and segments come back to the server. Segments
/// are then served by a `LoadingRequestWorker`, exactly like progressive files:
/// from disk where cached, otherwise downloaded once and written to disk.
///
/// Live playlists are passed through with their segments pointing at the origin,
/// and keys are never cached.
///
/// Confined to `IO.queue`.
final class HLSProxyServer: @unchecked Sendable {
    enum ResourceKind: String {
        case playlist = "p"
        case segment = "s"
    }

    private weak var cache: MediaCache?
    private var listener: NWListener?
    /// Kept across restarts, so URLs handed to existing items stay valid.
    private var port: NWEndpoint.Port?
    private var isReady = false
    private var isStopped = false
    private var readyWaiters: [DispatchSemaphore] = []
    private var connections: [ObjectIdentifier: HLSProxyConnection] = [:]
    private var sessions: [Int: HLSSession] = [:]
    private var nextSessionID = 1
    private let pathMonitor = NWPathMonitor()
    private var hasNetwork = true
    /// Replaces the network state, for tests.
    var isOnlineOverride: Bool?

    init(cache: MediaCache) {
        self.cache = cache
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.hasNetwork = path.status == .satisfied
        }
        pathMonitor.start(queue: IO.queue)
    }

    private var isOnline: Bool { isOnlineOverride ?? hasNetwork }

    // MARK: Sessions

    /// Registers a player item for the stream at `url` and returns the URL it
    /// should play, or `nil` if the server couldn't start. Must not be called on
    /// `IO.queue`; blocks briefly the first time while the server starts.
    func makeSession(
        for url: URL,
        eventHandler: @escaping @Sendable (ResourceLoader.Event) -> Void
    ) -> (session: HLSSession, assetURL: URL)? {
        dispatchPrecondition(condition: .notOnQueue(IO.queue))
        guard waitUntilReady() else { return nil }
        return IO.sync {
            guard let cache, let port, isReady else { return nil }
            let id = nextSessionID
            nextSessionID += 1
            let session = HLSSession(id: id, server: self, cache: cache, isComplete: cache.isHLSComplete(url), eventHandler: eventHandler)
            sessions[id] = session
            guard let assetURL = Self.proxyURL(for: url, kind: .playlist, sessionID: id, port: port) else { return nil }
            return (session, assetURL)
        }
    }

    func removeSession(_ id: Int) {
        dispatchPrecondition(condition: .onQueue(IO.queue))
        sessions[id] = nil
        for connection in connections.values where connection.sessionID == id {
            connection.close()
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(IO.queue))
        isStopped = true
        pathMonitor.cancel()
        listener?.cancel()
        listener = nil
        isReady = false
        for connection in Array(connections.values) { connection.close() }
        sessions = [:]
        signalReadyWaiters()
    }

    // MARK: Listener

    private func waitUntilReady(timeout: TimeInterval = 2) -> Bool {
        let waiter: DispatchSemaphore? = IO.sync {
            guard !isReady, !isStopped else { return nil }
            let semaphore = DispatchSemaphore(value: 0)
            readyWaiters.append(semaphore)
            if listener == nil { startListener() }
            return semaphore
        }
        if let waiter {
            _ = waiter.wait(timeout: .now() + timeout)
        }
        return IO.sync { isReady }
    }

    private func startListener() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port ?? .any)
        guard let listener = try? NWListener(using: parameters) else {
            signalReadyWaiters()
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            self.listenerStateChanged(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: IO.queue)
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port
            isReady = port != nil
            signalReadyWaiters()
        case .failed, .waiting:
            // E.g. the socket was reclaimed while the app was suspended. Listen
            // again on the same port, so existing items keep working.
            listener?.cancel()
            listener = nil
            isReady = false
            signalReadyWaiters()
            guard !isStopped, !sessions.isEmpty else { return }
            IO.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.isStopped, self.listener == nil else { return }
                self.startListener()
            }
        default:
            break
        }
    }

    private func signalReadyWaiters() {
        for waiter in readyWaiters { waiter.signal() }
        readyWaiters = []
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = HLSProxyConnection(connection: nwConnection)
        connections[ObjectIdentifier(connection)] = connection
        connection.onRequest = { [weak self] connection, request in
            self?.handle(request, on: connection)
        }
        connection.onClose = { [weak self] connection in
            self?.connections[ObjectIdentifier(connection)] = nil
            connection.worker?.cancel()
        }
        connection.start()
    }

    // MARK: Routing

    /// `/<session>/<kind>/<base64url of the remote URL>/<file name>`
    static func proxyURL(for url: URL, kind: ResourceKind, sessionID: Int, port: NWEndpoint.Port) -> URL? {
        let encoded = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        // The file name only helps when reading logs; AVFoundation goes by Content-Type.
        let name = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"]))
        let fileName = name.flatMap { $0.isEmpty || $0 == "%2F" ? nil : $0 } ?? (kind == .playlist ? "index.m3u8" : "segment")
        return URL(string: "http://127.0.0.1:\(port.rawValue)/\(sessionID)/\(kind.rawValue)/\(encoded)/\(fileName)")
    }

    private static func remoteURL(fromPathComponent component: Substring, query: String?) -> URL? {
        var base64 = component
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let string = String(data: data, encoding: .utf8),
              var components = URLComponents(string: string) else { return nil }
        // The player adds query items of its own for low-latency HLS.
        if let query, !query.isEmpty {
            components.percentEncodedQuery = [components.percentEncodedQuery, query].compactMap { $0 }.joined(separator: "&")
        }
        return components.url
    }

    private func handle(_ request: HLSProxyConnection.Request, on connection: HLSProxyConnection) {
        let parts = request.path.split(separator: "/")
        guard request.method == "GET" || request.method == "HEAD" else {
            connection.respond(status: 405)
            return
        }
        guard parts.count >= 3,
              let sessionID = Int(parts[0]),
              let kind = ResourceKind(rawValue: String(parts[1])),
              let url = Self.remoteURL(fromPathComponent: parts[2], query: request.query) else {
            connection.respond(status: 404)
            return
        }
        connection.sessionID = sessionID
        switch kind {
        case .playlist: servePlaylist(url, request: request, on: connection, session: sessions[sessionID])
        case .segment: serveSegment(url, request: request, on: connection, session: sessions[sessionID])
        }
    }

    // MARK: Playlists

    private func servePlaylist(_ url: URL, request: HLSProxyConnection.Request, on connection: HLSProxyConnection, session: HLSSession?) {
        guard let cache else { return connection.respond(status: 503) }
        if let playlist = cache.cachedPlaylist(for: url), playlist.isFinal {
            respond(with: playlist, for: url, on: connection, session: session)
            return
        }
        let fetch = PlaylistFetch { [weak self, weak connection] result in
            guard let self, let connection, !connection.isClosed else { return }
            switch result {
            case let .success((data, response)):
                let resolvedURL = response.url ?? url
                guard let playlist = HLSPlaylist(data: data, baseURL: resolvedURL) else {
                    // Not a playlist after all; pass it through untouched.
                    connection.respond(status: 200, headers: ["Content-Type": response.mimeType ?? "application/octet-stream"], body: data)
                    return
                }
                if playlist.isFinal {
                    self.cache?.storePlaylist(data, for: url, resolvedURL: resolvedURL, mimeType: response.mimeType)
                }
                self.respond(with: playlist, for: url, on: connection, session: session)
            case let .failure(error):
                session?.report(error)
                if case let PersistentAVPlayerItemError.unexpectedStatusCode(code) = error {
                    connection.respond(status: code)
                } else {
                    connection.respond(status: 502)
                }
            }
        }
        _ = cache.fetcher.startTask(with: URLRequest(url: url), handler: fetch)
    }

    private func respond(with playlist: HLSPlaylist, for url: URL, on connection: HLSProxyConnection, session: HLSSession?) {
        guard let cache, let port else { return connection.respond(status: 503) }
        let sessionID = connection.sessionID ?? 0
        func proxied(_ reference: HLSPlaylist.Reference, as kind: ResourceKind) -> HLSPlaylist.Rewrite {
            Self.proxyURL(for: reference.url, kind: kind, sessionID: sessionID, port: port).map { .replace($0) } ?? .keep
        }

        // Variants that can play entirely from disk are listed first, so playback
        // starts from disk. When the player mustn't switch to one that needs the
        // network (offline, or by policy), they're the only ones offered.
        var cachedVariants: Set<URL> = []
        var offersOnlyCachedVariants = false
        if playlist.isMultivariant {
            let playable = cache.playableVariants(of: playlist)
            cachedVariants = Set(playable.map(\.url))
            offersOnlyCachedVariants = playable.contains { $0.kind == .variant }
                && (cache.hlsVariantPolicy == .preferCached || !isOnline)
        }

        let text = playlist.rewritten(listFirst: { cachedVariants.contains($0.url) }) { reference in
            switch reference.kind {
            case .variant, .iFrameVariant:
                if offersOnlyCachedVariants, !cachedVariants.contains(reference.url) { return .drop }
                return proxied(reference, as: .playlist)
            case .rendition:
                return proxied(reference, as: .playlist)
            case .segment:
                // Live segments are short-lived; let the player fetch them directly.
                return playlist.isFinal ? proxied(reference, as: .segment) : .keep
            case .other:
                return .keep
            }
        }
        if !playlist.isMultivariant, playlist.isFinal {
            session?.track(playlist.references.filter { $0.kind == .segment })
        }
        connection.respond(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(text.utf8))
    }

    // MARK: Segments

    private func serveSegment(_ url: URL, request: HLSProxyConnection.Request, on connection: HLSProxyConnection, session: HLSSession?) {
        guard let cache else { return connection.respond(status: 503) }
        let file = cache.openFile(for: url, fileExtension: url.pathExtension.isEmpty ? nil : url.pathExtension)
        connection.prepareForSegment(request, file: file)
        let worker = LoadingRequestWorker(
            request: connection,
            file: file,
            fetcher: cache.fetcher,
            remoteURL: url,
            memoryBufferLimit: cache.memoryBufferLimit
        )
        connection.worker = worker
        worker.onError = { error in session?.report(error) }
        worker.onDone = { [weak self, weak connection] _ in
            connection?.worker = nil
            guard let self else { return }
            self.cache?.releaseFile(file)
            // Every item playing this stream, not only this one, may have progress to report.
            for session in self.sessions.values {
                session.segmentUpdated(url)
            }
        }
        worker.start()
    }
}

/// Downloads a playlist in one piece.
private final class PlaylistFetch: RemoteDataTaskHandler {
    private var completion: ((Result<(Data, URLResponse), Error>) -> Void)?
    private var response: URLResponse?
    private var data = Data()

    init(completion: @escaping (Result<(Data, URLResponse), Error>) -> Void) {
        self.completion = completion
    }

    func remoteTask(_ task: URLSessionTask, didReceive response: URLResponse) -> Bool {
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            finish(.failure(PersistentAVPlayerItemError.unexpectedStatusCode(response.statusCode)))
            return false
        }
        self.response = response
        return true
    }

    func remoteTask(_ task: URLSessionTask, didReceive data: Data) {
        self.data.append(data)
    }

    func remoteTask(_ task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else if let response {
            finish(.success((data, response)))
        } else {
            finish(.failure(PersistentAVPlayerItemError.invalidResponse))
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}
