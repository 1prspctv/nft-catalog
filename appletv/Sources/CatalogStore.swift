import Foundation
import SwiftUI

/// A set made in the web catalog and saved as an issue in the GitHub repo.
struct PieceSet: Identifiable, Hashable {
    let number: Int
    let title: String
    let keys: [String]
    var id: Int { number }
}

enum SetFormat {
    /// Body format written by the catalog:
    ///   tvset v1
    ///   contracts: KT1aaa KT1bbb
    ///   pieces: 0.123 0.45 1.7
    static func keys(fromBody body: String) -> [String]? {
        let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { $0.lowercased().hasPrefix("tvset v1") }) else { return nil }
        var contracts: [String] = []
        var keys: [String] = []
        for line in lines {
            if line.hasPrefix("contracts:") {
                contracts = line.dropFirst("contracts:".count).split(separator: " ").map(String.init)
            } else if line.hasPrefix("pieces:") {
                for item in line.dropFirst("pieces:".count).split(separator: " ") {
                    let parts = item.split(separator: ".", maxSplits: 1)
                    guard parts.count == 2, let ci = Int(parts[0]), ci >= 0, ci < contracts.count else { continue }
                    keys.append("\(contracts[ci]):\(parts[1])")
                }
            }
        }
        return keys
    }

    static func title(fromIssueTitle t: String) -> String {
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        if let r = trimmed.range(of: "tv set:", options: [.caseInsensitive, .anchored]) {
            let rest = trimmed[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? "Untitled set" : rest
        }
        return trimmed
    }
}

private struct GitHubIssue: Decodable {
    let number: Int
    let title: String
    let body: String?
    let state: String?
    let user: User?
    let pull_request: PR?
    struct User: Decodable { let login: String }
    struct PR: Decodable { let url: String? }
}

@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var pieces: [Piece] = []
    @Published private(set) var sets: [PieceSet] = []
    @Published private(set) var status: String = ""
    @Published private(set) var loading = false
    @Published private(set) var setsMessage: String = ""
    @Published private(set) var creatorNames: [String: String] = [:]
    /// IPFS URI of a WebM video -> URL of its MP4 copy on the catalog site.
    private(set) var mp4Copies: [String: URL] = [:]

    private var byKey: [String: Piece] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private var cacheFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("pieces-v1.json")
    }

    func piece(for key: String) -> Piece? { byKey[key] }

    func creatorLabel(_ p: Piece) -> String {
        if let n = creatorNames[p.creatorAddress], !n.isEmpty { return n }
        let a = p.creatorAddress
        return a.count > 14 ? "\(a.prefix(6))…\(a.suffix(4))" : a
    }

    func start() async {
        if pieces.isEmpty, let data = try? Data(contentsOf: cacheFile),
           let cached = try? JSONDecoder().decode([Piece].self, from: data) {
            apply(cached)
        }
        async let a: Void = refreshPieces()
        async let b: Void = refreshSets()
        async let c: Void = loadMP4Copies()
        _ = await (a, b, c)
        await loadCreatorNames()
    }

    private func apply(_ list: [Piece]) {
        pieces = list
        byKey = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func refreshPieces() async {
        loading = true
        defer { loading = false }
        if pieces.isEmpty { status = "Reading the collection…" }
        var out: [Piece] = []
        var offset = 0
        do {
            while true {
                var comps = URLComponents(string: "\(Catalog.tzkt)/v1/tokens/balances")!
                comps.queryItems = [
                    .init(name: "account", value: Catalog.account), .init(name: "balance.gt", value: "0"),
                    .init(name: "token.standard", value: "fa2"), .init(name: "limit", value: "500"),
                    .init(name: "offset", value: String(offset)), .init(name: "sort.asc", value: "id"),
                    .init(name: "select", value: "balance,token,firstTime")
                ]
                let (data, resp) = try await session.data(from: comps.url!)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let page = try JSONDecoder().decode([Lenient<TzktBalance>].self, from: data).compactMap { $0.value }
                out.append(contentsOf: page.compactMap(PieceBuilder.piece(from:)))
                if page.count < 500 { break }
                offset += 500
                if pieces.isEmpty { status = "Reading the collection… \(out.count) pieces so far" }
            }
            apply(out)
            status = ""
            if let data = try? JSONEncoder().encode(out) { try? data.write(to: cacheFile, options: .atomic) }
        } catch {
            status = pieces.isEmpty
                ? "Couldn't reach the Tezos data service. Check the Apple TV's internet connection and try again."
                : "Showing the collection as last loaded. The Tezos data service didn't answer just now."
        }
    }

    func refreshSets() async {
        var comps = URLComponents(string: "https://api.github.com/repos/\(Catalog.githubOwner)/\(Catalog.githubRepo)/issues")!
        comps.queryItems = [.init(name: "state", value: "open"), .init(name: "creator", value: Catalog.githubOwner),
                            .init(name: "per_page", value: "100")]
        do {
            let issues: [GitHubIssue] = try await getJSON(comps.url!)
            sets = issues.compactMap(makeSet)
            setsMessage = sets.isEmpty ? "No sets yet. In the catalog, pick pieces and choose Send to Apple TV." : ""
        } catch {
            setsMessage = "Couldn't load your sets from GitHub just now. You can still type a set number."
        }
    }

    /// Looks up one set by its number. Only sets opened by the catalog's own account are accepted.
    func fetchSet(number: Int) async -> Result<PieceSet, SetLookupError> {
        if let s = sets.first(where: { $0.number == number }) { return .success(s) }
        let url = URL(string: "https://api.github.com/repos/\(Catalog.githubOwner)/\(Catalog.githubRepo)/issues/\(number)")!
        do {
            let issue: GitHubIssue = try await getJSON(url)
            guard let s = makeSet(issue) else { return .failure(.notASet) }
            return .success(s)
        } catch let e as URLError where e.code == .fileDoesNotExist {
            return .failure(.notFound)
        } catch {
            return .failure(.network)
        }
    }

    private func makeSet(_ i: GitHubIssue) -> PieceSet? {
        guard i.pull_request == nil, i.user?.login.lowercased() == Catalog.githubOwner.lowercased(),
              let keys = SetFormat.keys(fromBody: i.body ?? ""), !keys.isEmpty else { return nil }
        return PieceSet(number: i.number, title: SetFormat.title(fromIssueTitle: i.title), keys: keys)
    }

    private func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw URLError(.fileDoesNotExist) }
        guard code == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func loadMP4Copies() async {
        let url = Catalog.siteBase.appendingPathComponent("media/index.json")
        guard let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        mp4Copies = map.compactMapValues { URL(string: $0, relativeTo: Catalog.siteBase)?.absoluteURL }
    }

    func mp4Copy(for uri: String) -> URL? { mp4Copies[uri] }

    private func loadCreatorNames() async {
        let addrs = Array(Set(pieces.map(\.creatorAddress).filter { !$0.isEmpty && creatorNames[$0] == nil }))
        guard !addrs.isEmpty else { return }
        var names: [String: String] = [:]
        struct Domain: Decodable { let address: String?; let name: String? }
        struct Account: Decodable { let address: String?; let alias: String? }
        for start in stride(from: 0, to: addrs.count, by: 40) {
            let chunk = addrs[start..<min(start + 40, addrs.count)].joined(separator: ",")
            if let ds: [Domain] = try? await getJSON(URL(string: "\(Catalog.tzkt)/v1/domains?address.in=\(chunk)&reverse=true&select=address,name&limit=100")!) {
                for d in ds { if let a = d.address, let n = d.name { names[a] = n } }
            }
            if let accs: [Account] = try? await getJSON(URL(string: "\(Catalog.tzkt)/v1/accounts?address.in=\(chunk)&select=address,alias&limit=100")!) {
                for a in accs { if let ad = a.address, let al = a.alias, names[ad] == nil { names[ad] = al } }
            }
        }
        creatorNames.merge(names) { a, _ in a }
    }
}

enum SetLookupError: Error {
    case notFound, notASet, network
    var message: String {
        switch self {
        case .notFound: return "There's no set with that number."
        case .notASet: return "That number isn't a set made from the catalog."
        case .network: return "Couldn't reach GitHub just now. Try again in a moment."
        }
    }
}
