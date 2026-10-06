// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import AVFoundation
import SwiftUI

struct VideoTileView: View {
    let video: SampleVideo
    @StateObject private var model: TileModel

    init(video: SampleVideo) {
        self.video = video
        _model = StateObject(wrappedValue: TileModel(video: video))
    }

    var body: some View {
        Color.black
            .aspectRatio(1, contentMode: .fit)
            .overlay(PlayerLayerView(player: model.player))
            .overlay(alignment: .topLeading) {
                CacheBadge(state: model.cacheState).padding(4)
            }
            .overlay(alignment: .bottomLeading) {
                Text(video.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .shadow(radius: 2)
                    .padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onAppear { model.play() }
            .onDisappear { model.pause() }
    }
}

private struct CacheBadge: View {
    let state: TileModel.CacheState

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private var label: String {
        switch state {
        case .fromDisk: return "DISK"
        case .streaming(let fraction): return "NET \(Int((fraction * 100).rounded()))%"
        case .saved: return "SAVED"
        case .failed: return "ERROR"
        }
    }

    private var color: Color {
        switch state {
        case .fromDisk: return .green
        case .streaming: return .orange
        case .saved: return .blue
        case .failed: return .red
        }
    }
}

/// Hosts an `AVPlayerLayer`. Lighter than SwiftUI's `VideoPlayer`, which adds
/// playback controls to every tile.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
