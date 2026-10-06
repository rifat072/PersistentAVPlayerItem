// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import AVFoundation

struct RequestedDataRange: Equatable {
    var offset: Int64
    var length: Int64
    var requestsAllDataToEndOfResource: Bool
}

/// The parts of `AVAssetResourceLoadingRequest` the worker uses. Abstracted so the
/// range and caching logic can be unit tested without AVFoundation.
protocol ResourceLoadingRequest: AnyObject {
    var wantsContentInformation: Bool { get }
    var requestedDataRange: RequestedDataRange? { get }
    var isCancelled: Bool { get }
    func setContentInformation(contentType: String, contentLength: Int64?, isByteRangeAccessSupported: Bool)
    func deliver(_ data: Data)
    func finish(error: Error?)
}

extension AVAssetResourceLoadingRequest: ResourceLoadingRequest {
    var wantsContentInformation: Bool { contentInformationRequest != nil }

    var requestedDataRange: RequestedDataRange? {
        guard let dataRequest else { return nil }
        return RequestedDataRange(
            offset: dataRequest.requestedOffset,
            length: Int64(dataRequest.requestedLength),
            requestsAllDataToEndOfResource: dataRequest.requestsAllDataToEndOfResource
        )
    }

    func setContentInformation(contentType: String, contentLength: Int64?, isByteRangeAccessSupported: Bool) {
        guard let info = contentInformationRequest else { return }
        info.contentType = contentType
        if let contentLength { info.contentLength = contentLength }
        info.isByteRangeAccessSupported = isByteRangeAccessSupported
    }

    func deliver(_ data: Data) {
        dataRequest?.respond(with: data)
    }

    func finish(error: Error?) {
        if let error {
            finishLoading(with: error)
        } else {
            finishLoading()
        }
    }
}
