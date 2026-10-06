// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

public enum PersistentAVPlayerItemError: Error, LocalizedError, Equatable {
    /// The server's response was not HTTP, or its `Content-Range` didn't match the request.
    case invalidResponse
    /// The server answered with a status code other than 200 or 206.
    case unexpectedStatusCode(Int)
    /// The server closed the connection before sending the requested bytes.
    case incompleteResponse

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an invalid response."
        case .unexpectedStatusCode(let code):
            return "The server returned HTTP status \(code)."
        case .incompleteResponse:
            return "The server ended the response before sending the requested data."
        }
    }
}
