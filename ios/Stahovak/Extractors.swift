import Foundation

// MARK: Platformy

enum Platform: String, CaseIterable, Identifiable, Codable {
    case youtube = "YT", x = "X", instagram = "IG", facebook = "FB", threads = "TH"
    var id: String { rawValue }

    var name: String {
        switch self {
        case .youtube: return "YouTube"
        case .x: return "X / Twitter"
        case .instagram: return "Instagram"
        case .facebook: return "Facebook"
        case .threads: return "Threads"
        }
    }

    private var hosts: [String] {
        switch self {
        case .youtube: return ["youtube.com", "youtu.be"]
        case .x: return ["x.com", "twitter.com"]
        case .instagram: return ["instagram.com"]
        case .facebook: return ["facebook.com", "fb.watch"]
        case .threads: return ["threads.net", "threads.com"]
        }
    }

    static func detect(_ s: String) -> Platform? {
        guard let host = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
        else { return nil }
        return allCases.first { p in p.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }
    }

    /// YouTube se na iPhonu sám stáhnout nedá (šifrované podpisy streamů), jde vždy přes Mac.
    var hasNativeExtractor: Bool { self != .youtube }
}

enum ExtractError: LocalizedError {
    case notFound(String)
    case badLink

    var errorDescription: String? {
        switch self {
        case .notFound(let s): return s
        case .badLink: return "Tomuhle odkazu nerozumím."
        }
    }
}

// MARK: Nativní extraktory (bez serveru)

enum Extractors {
    static let uaSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let uaDesktop = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    static let uaMeta = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"

    /// Vrátí přímou URL na video soubor.
    static func videoURL(for link: String, platform: Platform, log: (String) -> Void) async throws -> URL {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ExtractError.badLink }
        switch platform {
        case .threads: return try await threads(url, log: log)
        case .x: return try await twitter(url, log: log)
        case .instagram: return try await instagram(url, log: log)
        case .facebook: return try await facebook(url, log: log)
        case .youtube: throw ExtractError.notFound("YouTube jde jen přes Mac most.")
        }
    }

    // MARK: Threads (ověřeno: embed stránka má <source src> na CDN)

    static func threads(_ url: URL, log: (String) -> Void) async throws -> URL {
        // share odkaz se rozbalí přesměrováním
        let first = try await fetch(url, ua: uaDesktop)
        guard let canon = canonicalThreads(first.finalURL) ?? canonicalThreads(url) else {
            throw ExtractError.notFound("Z odkazu nejde poznat Threads post.")
        }
        log("Threads post: \(canon.path)")
        for ua in [uaDesktop, uaMeta, uaSafari] {
            let res = try await fetch(canon.appendingPathComponent("embed"), ua: ua)
            if let v = firstMediaURL(in: res.html) { return v }
        }
        throw ExtractError.notFound("Threads: video nenalezeno (post možná video nemá).")
    }

    static func canonicalThreads(_ u: URL) -> URL? {
        let c = u.pathComponents
        guard let i = c.firstIndex(of: "post"), i >= 1, i + 1 < c.count else { return nil }
        return URL(string: "https://www.threads.com/\(c[i - 1])/post/\(c[i + 1])")
    }

    // MARK: X / Twitter (veřejné syndication API, stejné jako embedy)

    static func twitter(_ url: URL, log: (String) -> Void) async throws -> URL {
        let c = url.pathComponents
        guard let i = c.firstIndex(of: "status"), i + 1 < c.count,
              let id = Int64(c[i + 1].prefix { $0.isNumber }) else {
            throw ExtractError.notFound("X: v odkazu chybí /status/ID.")
        }
        var comps = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")!
        comps.queryItems = [
            .init(name: "id", value: String(id)),
            .init(name: "lang", value: "en"),
            .init(name: "token", value: syndicationToken(id)),
        ]
        let res = try await fetch(comps.url!, ua: uaDesktop)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(res.html.utf8)) as? [String: Any] else {
            throw ExtractError.notFound("X: tweet nejde načíst (smazaný, soukromý nebo 18+).")
        }
        // video může být v tweetu samotném nebo v citovaném
        let candidates = [obj, obj["quoted_tweet"] as? [String: Any]].compactMap { $0 }
        for t in candidates {
            let media = (t["mediaDetails"] as? [[String: Any]]) ?? []
            for m in media {
                guard let info = m["video_info"] as? [String: Any],
                      let variants = info["variants"] as? [[String: Any]] else { continue }
                let mp4 = variants
                    .filter { ($0["content_type"] as? String) == "video/mp4" }
                    .max { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }
                if let s = mp4?["url"] as? String, let u = URL(string: s) {
                    log("X: \(variants.count) variant, beru nejvyšší bitrate")
                    return u
                }
            }
        }
        throw ExtractError.notFound("X: tweet nemá video.")
    }

    /// Token pro syndication API: JS `((id / 1e15) * Math.PI).toString(36)` bez nul a tečky.
    /// Převod do soustavy 36 kopíruje algoritmus V8 (DoubleToRadixCString), ať token sedí na znak.
    static func syndicationToken(_ id: Int64) -> String {
        let v = Double(id) / 1e15 * Double.pi
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var integer = floor(v)
        var fraction = v - integer
        var delta = max(0.5 * (v.nextUp - v), Double.leastNonzeroMagnitude)
        var frac: [Int] = []
        if fraction >= delta {
            repeat {
                fraction *= 36
                delta *= 36
                let d = Int(fraction)
                frac.append(d)
                fraction -= Double(d)
                if fraction > 0.5 || (fraction == 0.5 && d & 1 == 1), fraction + delta > 1 {
                    // zaokrouhlit nahoru s přenosem
                    while true {
                        guard let last = frac.popLast() else { integer += 1; break }
                        if last + 1 < 36 { frac.append(last + 1); break }
                    }
                    break
                }
            } while fraction >= delta
        }
        var out = ""
        var i = integer
        if i == 0 { out = "0" }
        while i > 0 {
            out = String(chars[Int(i.truncatingRemainder(dividingBy: 36))]) + out
            i = floor(i / 36)
        }
        out += String(frac.map { chars[$0] })
        return out.replacingOccurrences(of: "0", with: "")
    }

    // MARK: Instagram (embed stránka, funguje jen u veřejných postů)

    static func instagram(_ url: URL, log: (String) -> Void) async throws -> URL {
        let c = url.pathComponents
        guard let i = c.firstIndex(where: { ["p", "reel", "reels", "tv"].contains($0) }), i + 1 < c.count else {
            throw ExtractError.notFound("Instagram: v odkazu chybí /p/ nebo /reel/.")
        }
        let code = c[i + 1]
        log("Instagram: \(code)")
        let pages = [
            URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/")!,
            URL(string: "https://www.instagram.com/reel/\(code)/")!,
        ]
        for page in pages {
            for ua in [uaDesktop, uaMeta] {
                guard let res = try? await fetch(page, ua: ua) else { continue }
                if let v = firstMediaURL(in: res.html, extraKeys: ["video_url", "contentUrl"]) { return v }
            }
        }
        throw ExtractError.notFound("Instagram: video bez přihlášení nedostupné. Zkus Mac most.")
    }

    // MARK: Facebook (veřejná videa, nejméně spolehlivé)

    static func facebook(_ url: URL, log: (String) -> Void) async throws -> URL {
        for ua in [uaDesktop, uaSafari] {
            guard let res = try? await fetch(url, ua: ua) else { continue }
            if let v = firstMediaURL(in: res.html, extraKeys: [
                "browser_native_hd_url", "playable_url_quality_hd", "hd_src",
                "browser_native_sd_url", "playable_url", "sd_src",
            ]) { return v }
        }
        throw ExtractError.notFound("Facebook: video bez přihlášení nedostupné. Zkus Mac most.")
    }

    // MARK: Společné

    struct Page { let html: String; let finalURL: URL; let code: Int }

    static func fetch(_ url: URL, ua: String) async throws -> Page {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/json", forHTTPHeaderField: "Accept")
        req.setValue("cs,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        return Page(html: String(decoding: data, as: UTF8.self),
                    finalURL: resp.url ?? url,
                    code: (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Najde první URL videa v HTML. Klíče v extraKeys mají přednost (JSON "klíč":"url").
    static func firstMediaURL(in html: String, extraKeys: [String] = []) -> URL? {
        var patterns = extraKeys.map { #""\#($0)":"([^"]+)""# }
        patterns += [
            #""video_versions":\[\{[^\]]*?"url":"([^"]+)""#,
            #"<meta[^>]+property="og:video(?::secure_url|:url)?"[^>]+content="([^"]+)""#,
            #"<video[^>]+src="([^"]+)""#,
            #"<source[^>]+src="([^"]+)""#,
            #"(https:(?:\\/|/){2}[^"'\s<>]+?\.mp4[^"'\s<>]*)"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let r = Range(m.range(at: 1), in: html) else { continue }
                let clean = String(html[r])
                    .replacingOccurrences(of: "\\/", with: "/")
                    .replacingOccurrences(of: "\\u0025", with: "%")
                    .replacingOccurrences(of: "\\u0026", with: "&")
                    .replacingOccurrences(of: "&amp;", with: "&")
                // rsrc.php jsou UI assety Instagramu, ne obsah
                guard clean.hasPrefix("http"), !clean.contains(".jpg"), !clean.contains("rsrc.php"),
                      let u = URL(string: clean) else { continue }
                return u
            }
        }
        return nil
    }
}
