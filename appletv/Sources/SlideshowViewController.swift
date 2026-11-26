import AVFoundation
import SwiftUI
import UIKit

struct SlideshowSettings {
    var secondsPerImage: Double
    var shuffle: Bool
    var showTitles: Bool
    var videoSound: Bool
}

/// Full-screen slideshow. Siri Remote: left/right to skip, play/pause to pause, click to show the title, Menu/Back to leave.
final class SlideshowViewController: UIViewController {
    private let pieces: [Piece]
    private let settings: SlideshowSettings
    private let mp4Copy: (Piece) -> URL?
    private let creator: (Piece) -> String
    var onExit: (() -> Void)?

    private var index = 0
    private var current: UIView?
    private var currentPlayer: AVPlayer?
    private var showTask: Task<Void, Never>?
    private var advanceTimer: Timer?
    private var slideStarted = Date()
    private var paused = false
    private var failuresInARow = 0
    private var prepared: [Int: Task<SlideContent?, Never>] = [:]
    private var endObserver: NSObjectProtocol?

    private let caption = UILabel()
    private let captionSub = UILabel()
    private let captionBox = UIStackView()
    private let badge = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let message = UILabel()

    init(pieces: [Piece], startAt: Int = 0, settings: SlideshowSettings, mp4Copy: @escaping (Piece) -> URL?, creator: @escaping (Piece) -> String) {
        self.pieces = settings.shuffle ? pieces.shuffled() : pieces
        self.settings = settings
        self.mp4Copy = mp4Copy
        self.creator = creator
        self.index = settings.shuffle ? 0 : max(0, min(startAt, pieces.count - 1))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        message.textColor = UIColor(white: 0.75, alpha: 1)
        message.font = .systemFont(ofSize: 34, weight: .medium)
        message.numberOfLines = 0
        message.textAlignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)

        caption.font = .systemFont(ofSize: 44, weight: .semibold)
        caption.textColor = .white
        captionSub.font = .systemFont(ofSize: 30, weight: .regular)
        captionSub.textColor = UIColor(white: 0.8, alpha: 1)
        for l in [caption, captionSub] {
            l.layer.shadowColor = UIColor.black.cgColor; l.layer.shadowOpacity = 0.9; l.layer.shadowRadius = 8; l.layer.shadowOffset = .zero
        }
        captionBox.axis = .vertical
        captionBox.spacing = 6
        captionBox.addArrangedSubview(caption)
        captionBox.addArrangedSubview(captionSub)
        captionBox.translatesAutoresizingMaskIntoConstraints = false
        captionBox.alpha = 0
        view.addSubview(captionBox)

        badge.text = "  Paused  "
        badge.font = .systemFont(ofSize: 28, weight: .semibold)
        badge.textColor = .white
        badge.backgroundColor = UIColor(white: 0, alpha: 0.6)
        badge.layer.cornerRadius = 12
        badge.clipsToBounds = true
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(badge)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            message.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),
            captionBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
            captionBox.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -90),
            captionBox.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -70),
            badge.topAnchor.constraint(equalTo: view.topAnchor, constant: 60),
            badge.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -90)
        ])

        addPress(.menu) { [weak self] in self?.exit() }
        addPress(.playPause) { [weak self] in self?.togglePause() }
        addPress(.select) { [weak self] in self?.flashCaption() }
        addPress(.rightArrow) { [weak self] in self?.step(1) }
        addPress(.leftArrow) { [weak self] in self?.step(-1) }
        for dir in [UISwipeGestureRecognizer.Direction.left, .right] {
            let s = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            s.direction = dir
            view.addGestureRecognizer(s)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        if current == nil { show(index) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        stopAll()
    }

    // MARK: remote

    private var pressHandlers: [UIGestureRecognizer: () -> Void] = [:]
    private func addPress(_ type: UIPress.PressType, _ handler: @escaping () -> Void) {
        let g = UITapGestureRecognizer(target: self, action: #selector(pressed(_:)))
        g.allowedPressTypes = [NSNumber(value: type.rawValue)]
        view.addGestureRecognizer(g)
        pressHandlers[g] = handler
    }
    @objc private func pressed(_ g: UIGestureRecognizer) { pressHandlers[g]?() }
    @objc private func swiped(_ g: UISwipeGestureRecognizer) { step(g.direction == .left ? 1 : -1) }

    private func exit() {
        stopAll()
        onExit?()
    }

    private func togglePause() {
        paused.toggle()
        badge.isHidden = !paused
        if paused {
            advanceTimer?.invalidate()
            currentPlayer?.pause()
        } else {
            currentPlayer?.play()
            if currentPlayer == nil { scheduleAdvance(after: max(1, settings.secondsPerImage - Date().timeIntervalSince(slideStarted))) }
        }
    }

    private func step(_ d: Int) {
        guard !pieces.isEmpty else { return }
        show((index + d + pieces.count) % pieces.count)
    }

    // MARK: slides

    private func content(for i: Int) -> Task<SlideContent?, Never> {
        if let t = prepared[i] { return t }
        let p = pieces[i]
        let copy = mp4Copy(p)
        let t = Task { await MediaLoader.prepare(p, mp4Copy: copy) }
        prepared[i] = t
        return t
    }

    private func show(_ i: Int) {
        guard !pieces.isEmpty else {
            message.text = "This set has no pieces that can be shown on Apple TV."
            return
        }
        index = i
        advanceTimer?.invalidate()
        showTask?.cancel()
        // Keep only the slide being opened and the one after it.
        let keep: Set<Int> = [i, (i + 1) % pieces.count]
        for (k, t) in prepared where !keep.contains(k) { t.cancel(); prepared[k] = nil }

        spinner.startAnimating()
        message.text = nil
        let task = content(for: i)
        showTask = Task { [weak self] in
            let result = await task.value
            guard let self, !Task.isCancelled, self.index == i else { return }
            self.prepared[i] = nil
            self.spinner.stopAnimating()
            guard let result else {
                self.failuresInARow += 1
                if self.failuresInARow >= self.pieces.count {
                    self.message.text = "None of these pieces could be loaded. Check the Apple TV's internet connection."
                    return
                }
                self.step(1)
                return
            }
            self.failuresInARow = 0
            self.present(result, piece: self.pieces[i])
            _ = self.content(for: (i + 1) % self.pieces.count) // load the next one in the background
        }
    }

    private func present(_ c: SlideContent, piece: Piece) {
        let old = current
        let oldPlayer = currentPlayer
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        currentPlayer = nil

        let v: UIView
        switch c {
        case .image(let img, let pixelArt):
            let iv = UIImageView(image: img)
            iv.contentMode = .scaleAspectFit
            if pixelArt { iv.layer.magnificationFilter = .nearest }
            if img.images != nil { iv.startAnimating() }
            v = iv
        case .video(let player):
            let pv = PlayerView()
            pv.playerLayer.player = player
            pv.playerLayer.videoGravity = .resizeAspect
            player.isMuted = !settings.videoSound
            currentPlayer = player
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
                self?.videoEnded()
            }
            v = pv
        }
        v.frame = view.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.alpha = 0
        view.insertSubview(v, belowSubview: spinner)
        current = v
        slideStarted = Date()
        if !paused { currentPlayer?.play() }

        UIView.animate(withDuration: 0.8, animations: { v.alpha = 1; old?.alpha = 0 }) { _ in
            oldPlayer?.pause()
            old?.removeFromSuperview()
        }

        caption.text = piece.name
        captionSub.text = creator(piece)
        shownPiece = piece
        if settings.showTitles { flashCaption() }
        if currentPlayer == nil && !paused { scheduleAdvance(after: settings.secondsPerImage) }
    }

    private var shownPiece: Piece?

    /// Artist names can arrive after a slide is on screen.
    func refreshCaption() {
        if let p = shownPiece { captionSub.text = creator(p) }
    }

    /// Short videos loop until the slide time is used up; longer ones play once.
    private func videoEnded() {
        guard let p = currentPlayer else { return }
        if pieces.count == 1 || Date().timeIntervalSince(slideStarted) < settings.secondsPerImage {
            p.seek(to: .zero)
            if !paused { p.play() }
        } else {
            step(1)
        }
    }

    private func scheduleAdvance(after seconds: Double) {
        advanceTimer?.invalidate()
        guard pieces.count > 1 else { return }
        advanceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.step(1)
        }
    }

    private func flashCaption() {
        captionBox.layer.removeAllAnimations()
        captionBox.alpha = 1
        UIView.animate(withDuration: 1.0, delay: 5, options: [.allowUserInteraction]) { self.captionBox.alpha = 0 }
    }

    private func stopAll() {
        advanceTimer?.invalidate()
        showTask?.cancel()
        for t in prepared.values { t.cancel() }
        prepared.removeAll()
        currentPlayer?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}

final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct SlideshowView: UIViewControllerRepresentable {
    let pieces: [Piece]
    var startAt: Int = 0
    let settings: SlideshowSettings
    @ObservedObject var store: CatalogStore
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> SlideshowViewController {
        let vc = SlideshowViewController(pieces: pieces, startAt: startAt, settings: settings,
                                         mp4Copy: { [store] p in MainActor.assumeIsolated { store.mp4Copy(for: p.fullURI) } },
                                         creator: { [store] p in MainActor.assumeIsolated { store.creatorLabel(p) } })
        vc.onExit = onExit
        return vc
    }
    func updateUIViewController(_ vc: SlideshowViewController, context: Context) { vc.refreshCaption() }
}
