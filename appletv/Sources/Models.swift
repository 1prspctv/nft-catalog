import Foundation

/// One artwork held by the account, reduced to what the slideshow needs.
struct Piece: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case image, gif, video, interactive, audio, model, pdf, other, unknown, none }

    let key: String            // "<contract>:<tokenId>", same key the web catalog uses
    let name: String
    let creatorAddress: String
    let kind: Kind
    let mime: String
    let fullURI: String        // highest-resolution file
    let stillURI: String       // display image (used for interactive, audio, svg and as a fallback)
    let thumbURI: String
    let acquired: String

    var id: String { key }

    var isVideo: Bool { kind == .video }
    var isWebM: Bool { mime.lowercased().contains("webm") }
}

enum Catalog {
    static let account = "tz1VoGn5XyDDbTQ5J2dEeWTMszA9H2xsQUrt"
    static let accountName = "1prspctv.tez"
    static let githubOwner = "1prspctv"
    static let githubRepo = "nft-catalog"
    static let siteBase = URL(string: "https://1prspctv.github.io/nft-catalog/")!
    static let tzkt = "https://api.tzkt.io"
    static let gateways = ["https://cache.teia.rocks", "https://ipfs.io", "https://gateway.pinata.cloud", "https://dweb.link", "https://w3s.link"]
    static let henPlaceholder = "QmNrhZHUaEqxhyLfqoq1mtHSipkWHeT31LNHb1QEbDHgnc"
    static let domainsContract = "KT1GBZmSxmnKJXGMdMLbugPfLyUPmuLSMwKS"

    /// Every HTTP address a token URI can be fetched from, best gateway first.
    static func urls(for uri: String) -> [URL] {
        guard !uri.isEmpty else { return [] }
        if uri.hasPrefix("ipfs://") {
            var rest = String(uri.dropFirst(7))
            if rest.hasPrefix("ipfs/") { rest = String(rest.dropFirst(5)) }
            let pathOnly = rest.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rest
            // cache.teia.rocks only serves whole files by CID, not files inside a folder
            let gws = pathOnly.contains("/") ? Array(gateways.dropFirst()) : gateways
            return gws.compactMap { URL(string: "\($0)/ipfs/\(rest)") }
        }
        if uri.hasPrefix("onchfs://") { return [URL(string: "https://onchfs.fxhash2.xyz/" + uri.dropFirst(9))].compactMap { $0 } }
        if uri.hasPrefix("ar://") { return [URL(string: "https://arweave.net/" + uri.dropFirst(5))].compactMap { $0 } }
        if uri.hasPrefix("https://") || uri.hasPrefix("http://") {
            let fixed = uri.hasPrefix("http://") ? "https://" + uri.dropFirst(7) : uri
            return [URL(string: fixed)].compactMap { $0 }
        }
        if uri.hasPrefix("Qm") || uri.hasPrefix("baf") { return gateways.compactMap { URL(string: "\($0)/ipfs/\(uri)") } }
        return []
    }
}

// MARK: - TzKT decoding

struct TzktBalance: Decodable {
    let balance: String?
    let firstTime: String?
    let token: TzktToken?
}

struct TzktToken: Decodable {
    let tokenId: String?
    let standard: String?
    let contract: TzktContract?
    let metadata: TokenMetadata?
}

struct TzktContract: Decodable { let address: String?; let alias: String? }

struct TokenMetadata: Decodable {
    var name: String?
    var symbol: String?
    var decimals: String?
    var artifactUri: String?
    var displayUri: String?
    var thumbnailUri: String?
    var mime: String?
    var generatorUri: String?
    var formats: [Format]?
    var creators: [String]?

    struct Format: Decodable {
        var uri: String?
        var mimeType: String?
        var dimensions: Dimensions?
        var fileSize: FlexibleString?
    }
    struct Dimensions: Decodable { var value: String? }

    enum CodingKeys: String, CodingKey { case name, symbol, decimals, artifactUri, displayUri, thumbnailUri, mime, generatorUri, formats, creators }

    init(from decoder: Decoder) throws {
        // Token metadata is written by many different minting sites, so every field is read leniently.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(FlexibleString.self, forKey: k))?.value }
        name = str(.name); symbol = str(.symbol); decimals = str(.decimals)
        artifactUri = str(.artifactUri); displayUri = str(.displayUri); thumbnailUri = str(.thumbnailUri)
        mime = str(.mime); generatorUri = str(.generatorUri)
        formats = (try? c.decodeIfPresent([Lenient<Format>].self, forKey: .formats))?.compactMap { $0.value }
        if let list = try? c.decodeIfPresent([Lenient<FlexibleString>].self, forKey: .creators) {
            creators = list.compactMap { $0.value?.value }
        } else if let one = str(.creators) { creators = [one] }
    }
}

/// Decodes strings that are sometimes numbers.
struct FlexibleString: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int64.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else if let b = try? c.decode(Bool.self) { value = String(b) }
        else { throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "not a string")) }
    }
}

/// Skips array entries that don't decode instead of failing the whole array.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Picking the file to show (same rules as the web catalog)

enum PieceBuilder {
    static func area(_ f: TokenMetadata.Format?) -> Int {
        guard let v = f?.dimensions?.value else { return 0 }
        let nums = v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return nums.count >= 2 ? nums[0] * nums[1] : 0
    }

    static func kind(of mime: String, _ m: TokenMetadata, alias: String) -> Piece.Kind {
        let mime = mime.lowercased()
        if mime.hasPrefix("video/") { return .video }
        if mime == "image/gif" { return .gif }
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("model/") { return .model }
        if mime == "application/pdf" { return .pdf }
        if mime == "application/x-directory" || mime.contains("html") || m.generatorUri != nil
            || (m.artifactUri ?? "").range(of: "fxhash", options: .caseInsensitive) != nil
            || alias.range(of: "fxhash", options: .caseInsensitive) != nil { return .interactive }
        return mime.isEmpty ? .unknown : .other
    }

    static func piece(from b: TzktBalance) -> Piece? {
        guard let t = b.token, let contract = t.contract?.address, let tokenId = t.tokenId else { return nil }
        let alias = t.contract?.alias ?? ""
        guard let m = t.metadata else { return nil }
        if Int(m.decimals ?? "0") ?? 0 > 0 || contract == Catalog.domainsContract { return nil }

        let fm = (m.formats ?? []).filter { !($0.uri ?? "").isEmpty }
        let art = m.artifactUri ?? ""
        var pick: TokenMetadata.Format? = fm.first(where: { $0.uri == art })
        if pick == nil, !art.isEmpty { pick = .init(uri: art, mimeType: fm.first?.mimeType ?? m.mime, dimensions: nil, fileSize: nil) }
        if pick == nil { pick = fm.first }
        for f in fm where area(f) > area(pick) {
            let mt = f.mimeType ?? ""
            if mt.hasPrefix("image/") || mt.hasPrefix("video/") { pick = f }
        }
        let good: (String?) -> String? = { u in
            guard let u, !u.isEmpty, !u.contains(Catalog.henPlaceholder) else { return nil }
            return u
        }
        let mime = pick?.mimeType ?? m.mime ?? ""
        let k: Piece.Kind = pick == nil ? .none : kind(of: mime, m, alias: alias)
        let full = pick?.uri ?? ""
        let still = good(m.displayUri) ?? good(m.thumbnailUri) ?? ((k == .image || k == .gif) ? full : "")
        let thumb = good(m.thumbnailUri) ?? good(m.displayUri) ?? ((k == .image || k == .gif) ? full : "")
        let creator = (m.creators ?? []).first(where: { $0.hasPrefix("tz") || $0.hasPrefix("KT") }) ?? ""
        return Piece(key: "\(contract):\(tokenId)", name: (m.name?.isEmpty == false ? m.name! : "#\(tokenId)"),
                     creatorAddress: creator, kind: k, mime: mime, fullURI: full, stillURI: still,
                     thumbURI: thumb, acquired: b.firstTime ?? "")
    }
}
