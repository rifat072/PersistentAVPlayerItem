// PersistentAVPlayerItem — MIT License. See LICENSE for details.

import Combine
import PersistentAVPlayerItem
import SwiftUI

struct ContentView: View {
    @State private var tileCount = 15
    /// Changing this recreates every tile, and so every player item.
    @State private var generation = 0
    @State private var cacheSize: Int64 = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(SampleVideos.all.prefix(tileCount)) { video in
                        VideoTileView(video: video)
                    }
                }
                .id(generation)
                .padding(6)

                legend
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("\(tileCount) videos").font(.headline)
                        Text("Cache on disk: \(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        generation += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reload players")

                    Menu {
                        Picker("Videos", selection: $tileCount) {
                            ForEach(9...15, id: \.self) { Text("\($0) videos").tag($0) }
                        }
                        Button(role: .destructive) {
                            MediaCache.shared.clearAll()
                            generation += 1
                        } label: {
                            Label("Clear cache", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Options")
                }
            }
        }
        .navigationViewStyle(.stack)
        .onReceive(refreshTimer) { _ in
            Task.detached(priority: .utility) {
                let size = MediaCache.shared.totalSize
                await MainActor.run { cacheSize = size }
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NET – streaming; % of the file saved to disk so far")
            Text("SAVED – fully downloaded while playing")
            Text("DISK – played from the local file, no network")
            Text("Tap ↻ to recreate the players and see cached videos load from disk.")
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }
}
