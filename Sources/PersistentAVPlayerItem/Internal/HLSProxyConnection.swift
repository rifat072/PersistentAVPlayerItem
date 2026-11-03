// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation
import Network
import UniformTypeIdentifiers

/// One HTTP/1.1 connection to `HLSProxyServer`: it reads a single request, and
/// the response is written either in one piece or, for segments, by a
/// `LoadingRequestWorker` through the `ResourceLoadingRequest` conformance.
/// Every response closes the connection.
///
/// Confined to `IO.queue`.
final class HLSProxyConnection: @unchecked Sendable {
    struct Request {
        var method: String
        var path: String
        var query: String?
        /// Header values by lowercased name.
        var headers: [String: String]

        var sendsBody: Bool { method != "HEAD" }
    }

    static let maxRequestSize = 64 * 1024

    /// The player item the request belongs to, once the request is parsed.
    var sessionID: Int?
    /// Keeps the segment worker alive until it reports done.
    var worker: LoadingRequestWorker?
    var onRequest: ((HLSProxyConnection, Request) -> Void)?
    /// Called once, when the connection closes for any reason.
    var onClose: ((HLSProxyConnection) -> Void)?

    private let connection: NWConnection
    private var receiveBuffer = Data()
    private var request: Request?
    private(set) var isClosed = false

    // Segment response state.
    private var requestedRange: RequestedDataRange?
    private var file: CacheFile?
    private var contentType: String?
    private var contentLength: Int64?
    private var headersSent = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: IO.queue)
        receive()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        let onClose = self.onClose
        self.onClose = nil
        onRequest = nil
        onClose?(self)
    }

    /// Sends a complete response and closes the connection.
    func respond(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        guard !isClosed, !headersSent else { return }
        var headers = headers
        headers["Content-Length"] = String(body.count)
        sendHead(status: status, headers: headers)
        if request?.sendsBody ?? true {
            send(body)
        }
        sendEnd()
    }

    /// Makes this connection answer `request` as a byte-range request for a segment.
    func prepareForSegment(_ request: Request, file: CacheFile) {
        self.file = file
        guard let range = request.headers["range"].flatMap(Self.parseRange) else {
            requestedRange = RequestedDataRange(offset: 0, length: 0, requestsAllDataToEndOfResource: true)
            return
        }
        requestedRange = range
    }

    // MARK: Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if self.request != nil {
                // Only watching for the client hanging up.
                if isComplete || error != nil { self.close() } else { self.receive() }
                return
            }
            if let data { self.receiveBuffer.append(data) }
            if let request = self.parseRequest() {
                self.request = request
                self.receiveBuffer = Data()
                self.receive()
                self.onRequest?(self, request)
            } else if isComplete || error != nil || self.receiveBuffer.count > Self.maxRequestSize {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func parseRequest() -> Request? {
        guard let headerEnd = receiveBuffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: receiveBuffer[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            return Request(method: "", path: "", query: nil, headers: [:])
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = requestLine[1].split(separator: "?", maxSplits: 1)
        return Request(
            method: String(requestLine[0]),
            path: String(target[0]),
            query: target.count == 2 ? String(target[1]) : nil,
            headers: headers
        )
    }

    /// A single `bytes=<start>-[<end>]` range. Other forms are served as the whole resource.
    private static func parseRange(_ header: String) -> RequestedDataRange? {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes="), !value.contains(",") else { return nil }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let endText = bounds[1].trimmingCharacters(in: .whitespaces)
        if endText.isEmpty {
            return RequestedDataRange(offset: start, length: 0, requestsAllDataToEndOfResource: true)
        }
        guard let end = Int64(endText), end >= start else { return nil }
        return RequestedDataRange(offset: start, length: end - start + 1, requestsAllDataToEndOfResource: false)
    }

    // MARK: Sending

    private func sendHead(status: Int, headers: [String: String]) {
        headersSent = true
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        var headers = headers
        headers["Connection"] = "close"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        send(Data(head.utf8))
    }

    private func send(_ data: Data) {
        guard !isClosed, !data.isEmpty else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    /// Closes the connection once everything queued has been sent.
    private func sendEnd() {
        guard !isClosed else { return }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    /// Sends the status line and headers of a segment response.
    private func sendSegmentHeadIfNeeded() {
        guard !headersSent, !isClosed else { return }
        var headers = [
            "Accept-Ranges": "bytes",
            "Content-Type": file?.mimeType
                ?? contentType.flatMap { UTType($0)?.preferredMIMEType }
                ?? "application/octet-stream",
        ]
        guard let total = contentLength else {
            // Length unknown: send what arrives until the connection closes.
            sendHead(status: 200, headers: headers)
            return
        }
        let range = requestedRange ?? RequestedDataRange(offset: 0, length: 0, requestsAllDataToEndOfResource: true)
        let isPartial = range.offset > 0 || !range.requestsAllDataToEndOfResource
        guard isPartial else {
            headers["Content-Length"] = String(total)
            sendHead(status: 200, headers: headers)
            return
        }
        guard range.offset < total else {
            headers["Content-Range"] = "bytes */\(total)"
            headers["Content-Length"] = "0"
            sendHead(status: 416, headers: headers)
            return
        }
        let end = range.requestsAllDataToEndOfResource ? total - 1 : min(range.offset + range.length, total) - 1
        headers["Content-Range"] = "bytes \(range.offset)-\(end)/\(total)"
        headers["Content-Length"] = String(end - range.offset + 1)
        sendHead(status: 206, headers: headers)
    }
}

// MARK: ResourceLoadingRequest

extension HLSProxyConnection: ResourceLoadingRequest {
    /// Always needed: the length and type go into the response headers.
    var wantsContentInformation: Bool { true }

    /// `nil` for `HEAD`, which only needs the headers.
    var requestedDataRange: RequestedDataRange? {
        request?.sendsBody == false ? nil : requestedRange
    }

    var isCancelled: Bool { isClosed }

    func setContentInformation(contentType: String, contentLength: Int64?, isByteRangeAccessSupported: Bool) {
        self.contentType = contentType
        self.contentLength = contentLength
    }

    func deliver(_ data: Data) {
        sendSegmentHeadIfNeeded()
        send(data)
    }

    func finish(error: Error?) {
        guard !isClosed else { return }
        if error == nil {
            sendSegmentHeadIfNeeded()
            sendEnd()
        } else if !headersSent {
            respond(status: 502)
        } else {
            // Cut the body short so the player sees the failure.
            close()
        }
    }
}
