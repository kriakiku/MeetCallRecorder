import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Turns a `BackgroundMode` plus a meeting's identity into one ready-to-use
/// image at the canvas size.
///
/// Resolved once per call, before the first segment opens, because the
/// photo modes can go to the network and `FrameComposer` can't wait on
/// anything - it runs in the sample path. Whatever comes back is handed to
/// the composer and held for the life of the call.
///
/// Every path ends in an image: a failed download falls through to the
/// seeded gradient rather than returning nil, so a recording never silently
/// loses its background because wallhaven was down.
actor BackgroundLibrary {
    static let shared = BackgroundLibrary()

    private let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MeetCallRecorder/backgrounds", isDirectory: true)
    }()

    /// How long a cached page of search results stays usable. Long,
    /// because "top of the past year" barely moves day to day and the
    /// point of the cache is to not re-query for every single call.
    private static let listingLifetime: TimeInterval = 24 * 60 * 60

    /// Drawn backgrounds are pure functions of (seed, size), so they only
    /// need making once per run.
    private var drawnCache: [String: CGImage] = [:]

    private init() {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// `seed` identifies the meeting - owner app plus call ID. It's what
    /// makes the two "per meeting" modes stable across recordings.
    func background(mode: BackgroundMode, seed: String, size: CGSize) async -> CGImage? {
        switch mode {
        case .desktop:
            // The only mode that can legitimately come back nil: there may
            // be no desktop picture set at all, and the composer already
            // treats a missing background as plain black.
            return Self.desktopPicture(size: size)
        case .seededGradient:
            return await gradient(seed: seed, size: size)
        case .randomGradient:
            // Not cached: the seed is thrown away, so there would never
            // be a hit, and keying the cache on it would only grow it by
            // one dead bitmap per call.
            return await MainActor.run { BackgroundArtwork.gradient(seed: UUID().uuidString, size: size) }
        case .randomPhoto:
            return await photo(seed: nil, size: size)
        case .seededPhoto:
            return await photo(seed: seed, size: size)
        }
    }

    /// Cached per (seed, size) because it isn't free: the mesh is drawn
    /// by SwiftUI and rasterized, and the photo modes fall back to it,
    /// so a run with the network down would otherwise rebuild the same
    /// bitmap for every call.
    private func gradient(seed: String, size: CGSize) async -> CGImage? {
        let key = "grad-\(seed)-\(Int(size.width))x\(Int(size.height))"
        if let cached = drawnCache[key] { return cached }
        // Hops to the main actor: `MeshGradient` is a SwiftUI view and
        // `ImageRenderer` is main-actor only. It happens once per call,
        // before the first segment opens, so it is nowhere near the
        // sample path.
        guard let image = await MainActor.run(body: { BackgroundArtwork.gradient(seed: seed, size: size) }) else {
            return nil
        }
        drawnCache[key] = image
        return image
    }

    // MARK: - Photos

    /// A wallhaven wallpaper, cover-fitted to the canvas.
    ///
    /// `seed == nil` means "any" - a fresh pick each call. A seed means the
    /// pick is a pure function of it, so one recurring huddle keeps its
    /// picture. Both share the same two caches: the resolved wallpaper ID
    /// per seed, and the downloaded file per ID.
    private func photo(seed: String?, size: CGSize) async -> CGImage? {
        // The fallback for every failure below. Computed from the seed so
        // a meeting that can't reach the network still gets *its* colour
        // rather than an arbitrary one.
        let fallbackSeed = seed ?? UUID().uuidString

        if let seed, let id = rememberedWallpaperID(for: seed), let image = cachedPhoto(id: id, size: size) {
            return image
        }

        var rng = seed.map { SeededGenerator(seed: $0) } ?? SeededGenerator(seed: UUID().uuidString)
        let query = WallhavenClient.neutralQueries[rng.int(below: WallhavenClient.neutralQueries.count)]
        let page = 1 + rng.int(below: WallhavenClient.pageDepth)
        let index = rng.int(below: WallhavenClient.resultsPerPage)

        guard let listing = await listing(query: query, page: page), !listing.isEmpty else {
            log("background: no listing for \(query) p\(page) - falling back to a gradient")
            return await gradient(seed: fallbackSeed, size: size)
        }
        let wallpaper = listing[index % listing.count]

        if let seed { rememberWallpaperID(wallpaper.id, for: seed) }

        if let cached = cachedPhoto(id: wallpaper.id, size: size) {
            return cached
        }

        do {
            let data = try await WallhavenClient.shared.download(wallpaper)
            try data.write(to: photoURL(id: wallpaper.id))
            guard let image = Self.decode(data, fitting: size) else {
                log("background: \(wallpaper.id) downloaded but wouldn't decode - falling back to a gradient")
                return await gradient(seed: fallbackSeed, size: size)
            }
            return image
        } catch {
            log("background: download of \(wallpaper.id) failed (\(error)) - falling back to a gradient")
            return await gradient(seed: fallbackSeed, size: size)
        }
    }

    private func photoURL(id: String) -> URL {
        cacheDirectory.appendingPathComponent("photo-\(id).img")
    }

    private func cachedPhoto(id: String, size: CGSize) -> CGImage? {
        guard let data = try? Data(contentsOf: photoURL(id: id)) else { return nil }
        return Self.decode(data, fitting: size)
    }

    // MARK: - Listing cache

    private struct CachedListing: Codable {
        let fetchedAt: Date
        let wallpapers: [WallhavenClient.Wallpaper]
    }

    private func listingURL(query: String, page: Int) -> URL {
        // The query set is a fixed list of plain words, so this needs no
        // escaping beyond flattening whitespace.
        let safe = query.replacingOccurrences(of: " ", with: "-")
        return cacheDirectory.appendingPathComponent("list-\(safe)-\(page).json")
    }

    private func listing(query: String, page: Int) async -> [WallhavenClient.Wallpaper]? {
        let url = listingURL(query: query, page: page)
        if let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(CachedListing.self, from: data),
           Date().timeIntervalSince(cached.fetchedAt) < Self.listingLifetime {
            return cached.wallpapers
        }

        do {
            let wallpapers = try await WallhavenClient.shared.search(query: query, page: page)
            let encoded = try JSONEncoder().encode(CachedListing(fetchedAt: Date(), wallpapers: wallpapers))
            try? encoded.write(to: url)
            return wallpapers
        } catch {
            log("background: search '\(query)' p\(page) failed: \(error)")
            // A stale listing still beats no listing - the wallpapers it
            // names are almost certainly still there.
            if let data = try? Data(contentsOf: url),
               let cached = try? JSONDecoder().decode(CachedListing.self, from: data) {
                return cached.wallpapers
            }
            return nil
        }
    }

    // MARK: - Seed -> wallpaper map

    private var seedMapURL: URL { cacheDirectory.appendingPathComponent("seed-map.json") }

    private func seedMap() -> [String: String] {
        guard let data = try? Data(contentsOf: seedMapURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    private func rememberedWallpaperID(for seed: String) -> String? {
        seedMap()[seed]
    }

    /// Pinned on disk rather than recomputed every time: the hash picks a
    /// *position* in a listing, and the listing's contents drift as the
    /// year's top wallpapers change. Pinning the resolved ID is what makes
    /// "the same huddle keeps the same picture" survive that drift - and
    /// it means a repeat of a known meeting never calls the API at all.
    private func rememberWallpaperID(_ id: String, for seed: String) {
        var map = seedMap()
        guard map[seed] != id else { return }
        map[seed] = id
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: seedMapURL)
        }
    }

    // MARK: - Image helpers

    private static func desktopPicture(size: CGSize) -> CGImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return fit(image, to: size)
    }

    private static func decode(_ data: Data, fitting size: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return fit(image, to: size)
    }

    /// Cover-fit: scale up to fill `size` entirely, centre, crop the
    /// excess. Same rule the composer used for the desktop picture, moved
    /// here so every background arrives already canvas-shaped and the
    /// composer does no fitting of its own.
    static func fit(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let scaled = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (size.width - scaled.width) / 2,
            y: (size.height - scaled.height) / 2,
            width: scaled.width,
            height: scaled.height
        ))
        return context.makeImage()
    }

    private nonisolated func log(_ message: String) {
        Log.write(message)
    }
}
