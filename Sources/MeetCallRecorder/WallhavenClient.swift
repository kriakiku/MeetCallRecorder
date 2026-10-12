import Foundation

/// Minimal wallhaven.cc API client - a search and a download, both scoped
/// to what the background picker needs.
///
/// Deliberately *not* using the API's own `seed` parameter for the
/// per-meeting mode. It looks like it would do the job, but the server
/// ignores a client-supplied seed and returns one of its own: the same
/// seed sent twice came back as `qUWuS9` then `gYz5ww`, with different
/// results both times. Determinism is therefore done here instead - a
/// hash of the meeting ID picks a page and an index into a *stable*
/// ordering (`toplist`, fixed range), which doesn't depend on the server
/// honouring anything.
actor WallhavenClient {
    static let shared = WallhavenClient()

    struct Wallpaper: Codable, Sendable {
        let id: String
        /// Full-resolution image.
        let path: String
        let dimensionX: Int
        let dimensionY: Int
    }

    enum ClientError: Error {
        case badResponse(Int)
        case empty
        case malformed
    }

    /// Searches are restricted to `categories=100` (general - not anime,
    /// not people) and `purity=100` (SFW). These queries are the neutral
    /// end of that: scenery and texture, nothing with a subject that would
    /// be odd to find behind a work call.
    static let neutralQueries = [
        "landscape", "minimal", "nature", "mountains",
        "abstract", "architecture", "forest", "ocean", "sky"
    ]

    /// Pages deep enough to give variety, shallow enough that every page
    /// is still genuinely top-rated. The API reports ~50 pages for these
    /// queries.
    static let pageDepth = 12
    static let resultsPerPage = 24

    /// The API's documented ceiling is 45 requests/minute. One call start
    /// makes at most one search plus one download, so this is nowhere near
    /// it - the gap exists so a burst (several calls finalizing at once,
    /// or a retry loop that gets away from us) can't turn into a flood.
    private static let minimumRequestInterval: TimeInterval = 1.5
    private var lastRequest: Date?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// One page of results. Callers cache this; see `BackgroundLibrary`.
    func search(query: String, page: Int) async throws -> [Wallpaper] {
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "categories", value: "100"),
            URLQueryItem(name: "purity", value: "100"),
            URLQueryItem(name: "sorting", value: "toplist"),
            URLQueryItem(name: "topRange", value: "1y"),
            URLQueryItem(name: "ratios", value: "16x9"),
            URLQueryItem(name: "atleast", value: "1920x1080"),
            URLQueryItem(name: "page", value: String(page))
        ]
        guard let url = components.url else { throw ClientError.malformed }

        let data = try await get(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            throw ClientError.malformed
        }
        let wallpapers = items.compactMap { item -> Wallpaper? in
            guard let id = item["id"] as? String,
                  let path = item["path"] as? String,
                  let width = item["dimension_x"] as? Int,
                  let height = item["dimension_y"] as? Int else { return nil }
            return Wallpaper(id: id, path: path, dimensionX: width, dimensionY: height)
        }
        guard !wallpapers.isEmpty else { throw ClientError.empty }
        return wallpapers
    }

    func download(_ wallpaper: Wallpaper) async throws -> Data {
        guard let url = URL(string: wallpaper.path) else { throw ClientError.malformed }
        return try await get(url)
    }

    private func get(_ url: URL) async throws -> Data {
        if let lastRequest {
            let elapsed = Date().timeIntervalSince(lastRequest)
            if elapsed < Self.minimumRequestInterval {
                try await Task.sleep(for: .seconds(Self.minimumRequestInterval - elapsed))
            }
        }
        lastRequest = Date()

        var request = URLRequest(url: url)
        // The API asks for an identifying agent; an anonymous one gets
        // rate-limited harder.
        request.setValue("MeetCallRecorder/0.1 (+https://github.com/kriakiku)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badResponse(http.statusCode)
        }
        return data
    }
}
