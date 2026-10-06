// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Foundation

struct SampleVideo: Identifiable, Hashable {
    let id: Int
    let title: String
    let url: URL
}

/// Short public sample clips. All but the last support HTTP range requests; the
/// last one comes from a server that ignores `Range`, to show that fallback.
enum SampleVideos {
    static let all: [SampleVideo] = [
        ("Flower", "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4"),
        ("Friday", "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/friday.mp4"),
        ("Bunny 360p", "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4"),
        ("Jellyfish 360p", "https://test-videos.co.uk/vids/jellyfish/mp4/h264/360/Jellyfish_360_10s_1MB.mp4"),
        ("Sintel 360p", "https://test-videos.co.uk/vids/sintel/mp4/h264/360/Sintel_360_10s_1MB.mp4"),
        ("Bunny 720p", "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_2MB.mp4"),
        ("Jellyfish 720p", "https://test-videos.co.uk/vids/jellyfish/mp4/h264/720/Jellyfish_720_10s_2MB.mp4"),
        ("Sintel 720p", "https://test-videos.co.uk/vids/sintel/mp4/h264/720/Sintel_720_10s_2MB.mp4"),
        ("Sintel trailer", "https://media.w3.org/2010/05/sintel/trailer.mp4"),
        ("Bunny trailer", "https://media.w3.org/2010/05/bunny/trailer.mp4"),
        ("W3C movie", "https://media.w3.org/2010/05/video/movie_300.mp4"),
        ("Pexels 1", "https://videos.pexels.com/video-files/856973/856973-sd_640_360_25fps.mp4"),
        ("Pexels 2", "https://videos.pexels.com/video-files/3571264/3571264-sd_640_360_30fps.mp4"),
        ("Pexels 3", "https://videos.pexels.com/video-files/1409899/1409899-sd_640_360_25fps.mp4"),
        ("No-range server", "https://download.samplelib.com/mp4/sample-5s.mp4"),
    ]
    .enumerated()
    .map { SampleVideo(id: $0.offset, title: $0.element.0, url: URL(string: $0.element.1)!) }
}
