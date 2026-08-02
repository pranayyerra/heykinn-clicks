import SwiftUI
import AVFoundation

/// A bare, muted, looping video layer for hover previews — no transport
/// controls, no chrome. AVKit's `VideoPlayer` brings a control bar that would
/// be wrong inside a grid cell.
struct HoverPreviewLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = PlayerHostView()
        view.wantsLayer = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = view.bounds
        view.playerLayer = playerLayer
        view.layer?.addSublayer(playerLayer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? PlayerHostView else { return }
        host.playerLayer?.player = player
        host.layoutPlayerLayer()
    }

    /// AVPlayerLayer does not autoresize usefully inside SwiftUI, so the frame
    /// is kept in step with the view explicitly.
    final class PlayerHostView: NSView {
        var playerLayer: AVPlayerLayer?

        func layoutPlayerLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer?.frame = bounds
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            layoutPlayerLayer()
        }
    }
}

/// Owns the player for one hovered cell: muted, looping, and torn down as soon
/// as the pointer leaves so a grid full of cells never holds many players.
@MainActor
final class HoverPreviewController: ObservableObject {
    @Published private(set) var player: AVPlayer?

    /// Delay before a hover starts playback, so sweeping the pointer across
    /// the grid does not spin up a player for every cell it crosses.
    static let startDelay: Duration = .milliseconds(320)

    private var loopObserver: NSObjectProtocol?
    private var startTask: Task<Void, Never>?

    func hoverBegan(url: URL?) {
        guard let url else { return }
        startTask?.cancel()
        startTask = Task { [weak self] in
            try? await Task.sleep(for: Self.startDelay)
            guard !Task.isCancelled else { return }
            self?.start(url: url)
        }
    }

    func hoverEnded() {
        startTask?.cancel()
        startTask = nil
        stop()
    }

    private func start(url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true            // A grid should never make noise.
        newPlayer.actionAtItemEnd = .none   // Loop instead of freezing on the last frame.
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak newPlayer] _ in
            newPlayer?.seek(to: .zero)
            newPlayer?.play()
        }
        player = newPlayer
        newPlayer.play()
    }

    private func stop() {
        player?.pause()
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        player = nil
    }

    deinit {
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }
}
