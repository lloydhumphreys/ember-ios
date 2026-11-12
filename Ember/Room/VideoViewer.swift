import SwiftUI
import AVKit
import EmberSDK

/// A video from the server in the system's player, streamed with the signed-in session's cookies.
struct VideoViewer: View {
    let url: URL
    let cookies: [HTTPCookie]

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Color.black
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .background(.black)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .onAppear {
            guard player == nil else { return }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: Self.asset(url: url, cookies: cookies)))
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
    }

    static func asset(url: URL, cookies: [HTTPCookie]) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies])
    }

    /// The session's cookies for `url` when it's on the server itself, and none anywhere else.
    @MainActor static func cookies(for url: URL, client: EmberClient) -> [HTTPCookie] {
        guard FileDownloads.isSameOrigin(url, client.origin) else { return [] }
        return client.cookies.cookies(for: url) ?? []
    }
}
