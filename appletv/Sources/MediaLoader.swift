import AVFoundation
import ImageIO
import UIKit

/// What one slide shows once it's ready.
enum SlideContent {
    case image(UIImage, pixelArt: Bool)
    case video(AVPlayer)
}

enum MediaLoader {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.timeoutIntervalForResource = 180
        c.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        return URLSession(configuration: c)
    }()

    /// Gets the piece ready to show, trying each gateway in turn. Returns nil if nothing could be loaded.
    static func prepare(_ p: Piece, mp4Copy: URL?) async -> SlideContent? {
        if p.isVideo {
            var urls: [URL] = []
            if p.isWebM { if let mp4Copy { urls = [mp4Copy] } } else { urls = Catalog.urls(for: p.fullURI) }
            for url in urls {
                if Task.isCancelled { return nil }
                if let player = await readyPlayer(url) { return .video(player) }
            }
            return await image(p.stillURI)
        }
        if p.kind == .image || p.kind == .gif {
            if !p.mime.contains("svg"), let c = await image(p.fullURI) { return c }
            if p.stillURI != p.fullURI { return await image(p.stillURI) }
            return nil
        }
        return await image(p.stillURI)
    }

    private static func image(_ uri: String) async -> SlideContent? {
        for url in Catalog.urls(for: uri) {
            if Task.isCancelled { return nil }
            guard let (data, resp) = try? await session.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { continue }
            if let decoded = await Task.detached(priority: .userInitiated, operation: { decode(data) }).value {
                return .image(decoded.0, pixelArt: decoded.1)
            }
        }
        return nil
    }

    /// Decodes still and animated images, scaled down so very large files don't exhaust memory.
    static func decode(_ data: Data) -> (UIImage, Bool)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let pixelArt = max(w, h) > 0 && max(w, h) <= 512

        if count == 1 {
            guard let cg = thumb(src, 0, maxPixel: 3840) else { return nil }
            return (UIImage(cgImage: cg), pixelArt)
        }
        // Animated: keep all frames within about 300 MB.
        let frames = min(count, 600)
        let budget = 75_000_000.0 // pixels across all frames
        let perFrame = budget / Double(frames)
        let side = Double(max(w, h, 1))
        let scale = min(1.0, (perFrame / Double(max(w * h, 1))).squareRoot())
        let maxPixel = max(64, Int(side * scale))
        var images: [UIImage] = []
        var total = 0.0
        for i in 0..<frames {
            guard let cg = thumb(src, i, maxPixel: min(maxPixel, 1920)) else { continue }
            images.append(UIImage(cgImage: cg))
            total += frameDelay(src, i)
        }
        guard !images.isEmpty else { return nil }
        if images.count == 1 { return (images[0], pixelArt) }
        return (UIImage.animatedImage(with: images, duration: max(total, 0.1)) ?? images[0], pixelArt)
    }

    private static func thumb(_ src: CGImageSource, _ i: Int, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(src, i, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary)
    }

    private static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] ?? [:]
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
        ]
        for (dk, uk, dk2) in dicts {
            if let d = p[dk] as? [CFString: Any] {
                let v = (d[uk] as? Double) ?? (d[dk2] as? Double) ?? 0
                return v < 0.02 ? 0.1 : v
            }
        }
        return 0.1
    }

    /// Returns a player once its item is ready, or nil if it fails or takes longer than 20 seconds.
    private static func readyPlayer(_ url: URL) async -> AVPlayer? {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 10
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            switch item.status {
            case .readyToPlay: return player
            case .failed: return nil
            default: try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        return nil
    }
}
