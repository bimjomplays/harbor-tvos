import Foundation

/// (parity pass 3, H4) bp-poster-chain.ts useBpPosterChain for a poster-shaped tile, the part that
/// is URL building only: lib/providers/rpdb.ts rpdbPoster(settings.rpdbKey, meta.id, meta.poster)
/// under settings.posterBaseUrl (RPDB by default, or a poster host / "{imdbId}" template set on
/// desktop). The tile shows this url and falls back to the plain poster when it fails to load
/// (usePosterChain onError). Not ported: the poster pinned on the desktop detail page
/// (lib/title-poster, a desktop-local store the TV never receives), the TMDB id lookups some hosts
/// need (useRpdbAltId, the anime id mapping) and TMDB's localized poster (useLocalizedPoster):
/// those ids fall back to the plain poster, as upstream's chain does while they resolve.
enum PosterChain {
    private struct ParsedId {
        var imdb: String?
        var tmdbId: String?
        var tvdbId: String?
        var mediaType: String
    }

    /// useBpPosterChain: the override for this tile, or nil for the plain poster ("the chain falls
    /// back to meta.poster itself. Handing that back as an override would route the plain poster
    /// around bpCardArt").
    @MainActor static func override(for meta: Meta) -> String? {
        let slice = SettingsBridge.shared.slice
        let key: String = slice.rpdbKey ?? ""
        let base: String = normalizedBase(slice.posterBaseUrl ?? "")
        guard !key.isEmpty || !base.isEmpty else { return nil }
        guard let src = rpdbPoster(key: key, metaId: meta.id, base: base), src != meta.poster else { return nil }
        return src
    }

    /// rpdb.ts setPosterBaseUrl: trimmed, trailing slashes dropped.
    static func normalizedBase(_ url: String) -> String {
        var out = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// rpdb.ts parseMetaId.
    private static func parse(_ metaId: String) -> ParsedId? {
        if metaId.isEmpty { return nil }
        if metaId.hasPrefix("tt") { return ParsedId(imdb: metaId, tmdbId: nil, tvdbId: nil, mediaType: "movie") }
        let parts = metaId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[0] == "tmdb", parts[1] == "movie" || parts[1] == "tv", isDigits(parts[2]) {
            return ParsedId(imdb: nil, tmdbId: parts[2], tvdbId: nil, mediaType: parts[1] == "tv" ? "series" : "movie")
        }
        if parts.count == 2, parts[0] == "tvdb", isDigits(parts[1]) {
            return ParsedId(imdb: nil, tmdbId: nil, tvdbId: parts[1], mediaType: "series")
        }
        return nil
    }

    private static func isDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// rpdb.ts fillTemplate: every token the template uses must have a value.
    private static func fillTemplate(_ template: String, _ id: ParsedId) -> String? {
        let idToken: String? = id.imdb ?? id.tmdbId.map { "\(id.mediaType)-\($0)" }
        guard let idToken else { return nil }
        var out = template
        func sub(_ token: String, _ value: String?) -> Bool {
            guard out.contains(token) else { return true }
            guard let value else { return false }
            out = out.replacingOccurrences(of: token, with: value)
            return true
        }
        guard sub("{imdbId}", id.imdb), sub("{imdb_id}", id.imdb), sub("{tmdbId}", id.tmdbId), sub("{tmdb_id}", id.tmdbId) else { return nil }
        _ = sub("{type}", id.mediaType)
        _ = sub("{mediaType}", id.mediaType)
        guard sub("{id}", idToken) else { return nil }
        return out
    }

    /// rpdb.ts rpdbPath.
    private static func rpdbPath(_ base: String, _ key: String, _ id: ParsedId) -> String? {
        guard !key.isEmpty else { return nil }
        if let imdb = id.imdb { return "\(base)/\(key)/imdb/poster-default/\(imdb).jpg?fallback=true" }
        if let tmdb = id.tmdbId { return "\(base)/\(key)/tmdb/poster-default/\(id.mediaType)-\(tmdb).jpg?fallback=true" }
        if let tvdb = id.tvdbId { return "\(base)/\(key)/tvdb/poster-default/series-\(tvdb).jpg?fallback=true" }
        return nil
    }

    /// rpdb.ts betterPostersPath.
    private static func betterPostersPath(_ base: String, _ id: ParsedId) -> String? {
        guard let imdb = id.imdb else { return nil }
        return "\(base)/poster/imdb/poster-default/\(imdb).jpg"
    }

    /// rpdb.ts postersPlusPath (needs both ids, so only a lookup could fill it here).
    private static func postersPlusPath(_ base: String, _ id: ParsedId) -> String? {
        guard let imdb = id.imdb, let tmdb = id.tmdbId else { return nil }
        var root = base
        if root.lowercased().hasSuffix("/poster") { root.removeLast("/poster".count) }
        let type: String = id.mediaType == "series" ? "series" : "movie"
        return "\(root)/poster?tmdb_id=\(tmdb)&imdb_id=\(imdb)&type=\(type)"
    }

    /// rpdb.ts rpdbPoster(key, metaId, fallback) with no alt id: nil where upstream returns the
    /// fallback (the plain poster).
    static func rpdbPoster(key: String, metaId: String, base: String) -> String? {
        guard let id = parse(metaId) else { return nil }
        if base.contains("{") { return fillTemplate(base, id) }
        if base.isEmpty {
            guard !key.isEmpty else { return nil }
            return rpdbPath("https://api.ratingposterdb.com", key, id)
        }
        let host = base.lowercased()
        if host.contains("ratingposterdb.com") { return rpdbPath(base, key, id) }
        if host.contains("btttr.cc") { return betterPostersPath(base, id) }
        if host.contains("postersplus") || host.contains("elfhosted") { return postersPlusPath(base, id) }
        if !key.isEmpty { return rpdbPath(base, key, id) }
        return nil
    }
}
