import SwiftUI
import AppKit

enum Mode: String { case video, audio }

enum Platform: String, CaseIterable, Identifiable {
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
}

struct HistoryItem: Codable, Identifiable, Equatable {
    var id = UUID()
    let path: String
    let date: Date
    let platform: String
    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

enum CookieSource: String, CaseIterable, Identifiable {
    case none, safari, chrome, firefox, brave
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Bez cookies"
        case .safari: return "Cookies ze Safari"
        case .chrome: return "Cookies z Chrome"
        case .firefox: return "Cookies z Firefoxu"
        case .brave: return "Cookies z Brave"
        }
    }
    var short: String {
        self == .none ? "BEZ COOKIES" : rawValue.uppercased()
    }
}

enum Tools {
    static func find(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

/// Drží běžící proces kvůli tlačítku Zrušit.
final class ProcBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _p: Process?
    var process: Process? {
        get { lock.lock(); defer { lock.unlock() }; return _p }
        set { lock.lock(); _p = newValue; lock.unlock() }
    }
}

/// Skládá výstup procesu do celých řádků (yt-dlp posílá i \r).
final class LineSplitter: @unchecked Sendable {
    private var buf = ""
    private let lock = NSLock()
    private let emit: @Sendable (String) -> Void
    init(_ emit: @escaping @Sendable (String) -> Void) { self.emit = emit }

    func feed(_ data: Data, flush: Bool = false) {
        lock.lock()
        buf += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let r = buf.firstIndex(where: { $0.isNewline }) {
            lines.append(String(buf[..<r]))
            buf = String(buf[buf.index(after: r)...])
        }
        if flush, !buf.isEmpty { lines.append(buf); buf = "" }
        lock.unlock()
        for l in lines where !l.trimmingCharacters(in: .whitespaces).isEmpty { emit(l) }
    }
}

@MainActor
final class Downloader: ObservableObject {
    @Published var url = ""
    @Published var status = "Vlož odkaz nebo ho přetáhni do okna"
    @Published var progress: Double?
    @Published var log = ""
    @Published var busy = false
    @Published var lastFile: URL?
    @Published var history: [HistoryItem] = [] {
        didSet {
            if let d = try? JSONEncoder().encode(history) { UserDefaults.standard.set(d, forKey: "history") }
        }
    }

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var cookies: CookieSource {
        didSet { UserDefaults.standard.set(cookies.rawValue, forKey: "cookies") }
    }
    @Published var outputDir: URL {
        didSet { UserDefaults.standard.set(outputDir.path, forKey: "outputDir") }
    }

    private let box = ProcBox()
    private var cancelled = false

    static let supportedHosts = ["youtube.com", "youtu.be", "x.com", "twitter.com", "instagram.com",
                                 "facebook.com", "fb.watch", "threads.net", "threads.com"]

    init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .video
        cookies = CookieSource(rawValue: d.string(forKey: "cookies") ?? "") ?? .none
        if let p = d.string(forKey: "outputDir") {
            outputDir = URL(fileURLWithPath: p)
        } else {
            outputDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/Stahovak")
        }
        if let data = d.data(forKey: "history"),
           let h = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = h
        }
    }

    func clearHistory() { history = [] }

    // MARK: UI akce

    func pasteFromClipboard(onlyIfSupported: Bool = false) {
        guard let s = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              s.hasPrefix("http") else { return }
        if onlyIfSupported {
            guard let host = URL(string: s)?.host?.lowercased(),
                  Self.supportedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
            else { return }
        }
        url = s
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputDir
        if panel.runModal() == .OK, let u = panel.url { outputDir = u }
    }

    func cancel() {
        cancelled = true
        box.process?.terminate()
        status = "Zrušeno"
    }

    func start() {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !busy else { return }
        busy = true
        cancelled = false
        progress = nil
        lastFile = nil
        log = ""

        Task {
            defer { busy = false }
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let isThreads = link.contains("threads.com") || link.contains("threads.net")

            // Threads: yt-dlp ani gallery-dl ho neumí, jdeme rovnou vlastní cestou
            if isThreads {
                if await tryThreads(link) { return finish() }
                if cancelled { return }
            }
            if await tryYtDlp(link) { return finish() }
            if cancelled { return }
            if mode == .video && !isThreads {
                if await tryGalleryDl(link) { return finish() }
            }
            if !cancelled {
                status = "Nepovedlo se. Mrkni do logu, zkus cookies."
                NSSound(named: "Basso")?.play()
            }
        }
    }

    func updateTools() {
        busy = true
        log = ""
        progress = nil
        status = "Aktualizuju…"
        Task {
            defer { busy = false }
            var code: Int32 = -1
            if let brew = Tools.find("brew") {
                code = await run(brew, ["upgrade", "yt-dlp", "gallery-dl"])
            } else if let y = Tools.find("yt-dlp") {
                code = await run(y, ["-U"])
            }
            status = code == 0 ? "Nástroje aktuální ✓" : "Aktualizace selhala, viz log"
        }
    }

    // MARK: Strategie

    private var cookieArgs: [String] {
        cookies == .none ? [] : ["--cookies-from-browser", cookies.rawValue]
    }

    private func tryYtDlp(_ link: String) async -> Bool {
        guard let ytdlp = Tools.find("yt-dlp") else {
            appendLog("yt-dlp nenalezen. Spusť: brew install yt-dlp ffmpeg gallery-dl")
            return false
        }
        status = "yt-dlp…"
        var args = [
            "--newline", "--no-playlist", "--progress",
            "--progress-template",
            "download:PROG %(progress.downloaded_bytes)s %(progress.total_bytes,progress.total_bytes_estimate)s",
            "--print", "after_move:FILE %(filepath)s",
            "-o", outputDir.path + "/%(extractor_key)s - %(title).80B [%(id)s].%(ext)s",
        ]
        if let ff = Tools.find("ffmpeg") { args += ["--ffmpeg-location", ff] }
        switch mode {
        case .video:
            // H.264 + AAC kvůli QuickTime a Fotkám, jinak co je k mání
            args += ["-f", "bv*+ba/b", "-S", "vcodec:h264,res,acodec:m4a", "--merge-output-format", "mp4"]
        case .audio:
            args += ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
        }
        args += cookieArgs
        args.append(link)
        return await run(ytdlp, args) == 0 && !cancelled
    }

    private func tryGalleryDl(_ link: String) async -> Bool {
        guard let gdl = Tools.find("gallery-dl") else {
            appendLog("gallery-dl nenalezen, přeskakuju.")
            return false
        }
        status = "gallery-dl…"
        progress = nil
        var args = ["-d", outputDir.path]
        args += cookieArgs
        args.append(link)
        return await run(gdl, args) == 0 && !cancelled
    }

    // MARK: Threads

    private static let uaSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let uaMeta = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"
    private static let uaGoogle = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

    private func fetchHTML(_ u: URL, ua: String) async -> (html: String, finalURL: URL, code: Int)? {
        var req = URLRequest(url: u)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("cs,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (String(decoding: data, as: UTF8.self), resp.url ?? u, code)
    }

    /// threads.com/share/XYZ i /@user/post/CODE?xmt=… převede na čisté /@user/post/CODE
    nonisolated static func canonicalThreads(_ u: URL) -> URL? {
        let c = u.pathComponents
        guard let i = c.firstIndex(of: "post"), i >= 1, i + 1 < c.count else { return nil }
        return URL(string: "https://www.threads.com/\(c[i - 1])/post/\(c[i + 1])")
    }

    nonisolated static func extractVideoURL(_ html: String) -> URL? {
        let patterns = [
            #""video_versions":\[\{[^\]]*?"url":"([^"]+)""#,
            #"<meta[^>]+property="og:video(?::secure_url|:url)?"[^>]+content="([^"]+)""#,
            #"<meta[^>]+content="([^"]+)"[^>]+property="og:video"#,
            #"<video[^>]+src="([^"]+)""#,
            #"<source[^>]+src="([^"]+)""#,
            #"(https:(?:\\/|/){2}[^"'\s<>]+?\.mp4[^"'\s<>]*)"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            for m in re.matches(in: html, range: range) {
                guard let r = Range(m.range(at: 1), in: html) else { continue }
                let clean = String(html[r])
                    .replacingOccurrences(of: "\\/", with: "/")
                    .replacingOccurrences(of: "\\u0026", with: "&")
                    .replacingOccurrences(of: "&amp;", with: "&")
                // static.cdninstagram.com/rsrc.php jsou UI assety, ne obsah postu
                guard clean.hasPrefix("http"), !clean.contains(".jpg"), !clean.contains("rsrc.php"),
                      let u = URL(string: clean) else { continue }
                return u
            }
        }
        return nil
    }

    /// Threads: rozbalí share odkaz, zkusí embed i normální stránku s několika user agenty.
    private func tryThreads(_ link: String) async -> Bool {
        guard let start = URL(string: link) else { return false }
        status = "Threads, hledám video…"
        var debug = ""

        var post = start
        if let first = await fetchHTML(start, ua: Self.uaSafari) {
            post = first.finalURL
            appendLog("Threads: odkaz vede na \(post.absoluteString.prefix(100))")
        }
        guard let canon = Self.canonicalThreads(post) else {
            appendLog("Threads: z odkazu nejde poznat post (\(post.path)).")
            return false
        }

        let pages = [canon.appendingPathComponent("embed"), canon]
        let agents = [("Safari", Self.uaSafari), ("Meta", Self.uaMeta), ("Google", Self.uaGoogle)]
        for page in pages {
            for (name, ua) in agents {
                if cancelled { return false }
                guard let res = await fetchHTML(page, ua: ua) else { continue }
                appendLog("Threads: \(page.lastPathComponent == "embed" ? "embed" : "post") + \(name) → HTTP \(res.code), \(res.html.count) znaků")
                if let v = Self.extractVideoURL(res.html) { return await saveThreads(v) }
                debug += "=== \(page) [\(name)] HTTP \(res.code)\n\(res.html)\n\n"
            }
        }

        let dbg = outputDir.appendingPathComponent("threads-debug.txt")
        try? debug.write(to: dbg, atomically: true, encoding: .utf8)
        appendLog("Threads: video nenalezeno. Odpovědi serveru uloženy do \(dbg.path)")
        return false
    }

    private func saveThreads(_ video: URL) async -> Bool {
        appendLog("Threads video: \(video.absoluteString.prefix(120))…")
        status = "Threads, stahuju…"
        do {
            var req = URLRequest(url: video)
            req.setValue(Self.uaSafari, forHTTPHeaderField: "User-Agent")
            let (tmp, _) = try await URLSession.shared.download(for: req)
            let stamp = Int(Date().timeIntervalSince1970)
            let mp4 = outputDir.appendingPathComponent("Threads - \(stamp).mp4")
            try FileManager.default.moveItem(at: tmp, to: mp4)
            lastFile = mp4

            if mode == .audio, let ff = Tools.find("ffmpeg") {
                status = "Převádím na MP3…"
                let mp3 = mp4.deletingPathExtension().appendingPathExtension("mp3")
                if await run(ff, ["-y", "-i", mp4.path, "-vn", "-q:a", "0", mp3.path]) == 0 {
                    try? FileManager.default.removeItem(at: mp4)
                    lastFile = mp3
                }
            }
            return true
        } catch {
            appendLog("Threads: \(error.localizedDescription)")
            return false
        }
    }

    private func finish() {
        progress = 1
        status = "Hotovo ✓ " + (lastFile?.lastPathComponent ?? "")
        if let f = lastFile {
            let tag = Platform.detect(url)?.rawValue ?? "WEB"
            withAnimation(.spring(duration: 0.35)) {
                history.insert(HistoryItem(path: f.path, date: Date(), platform: tag), at: 0)
                if history.count > 50 { history.removeLast(history.count - 50) }
            }
        }
        NSSound(named: "Glass")?.play()
    }

    // MARK: Proces

    private func appendLog(_ s: String) {
        log += s + "\n"
        if log.count > 30_000 { log = String(log.suffix(20_000)) }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("PROG ") {
            let parts = line.split(separator: " ")
            if parts.count >= 3, let done = Double(parts[1]), let total = Double(parts[2]), total > 0 {
                progress = min(done / total, 1)
                status = String(format: "Stahuju… %.0f %%", done / total * 100)
            }
            return
        }
        if line.hasPrefix("FILE ") {
            lastFile = URL(fileURLWithPath: String(line.dropFirst(5)))
        } else if line.hasPrefix("/") {
            // gallery-dl vypisuje cesty stažených souborů
            lastFile = URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces))
        }
        appendLog(line)
    }

    nonisolated private func run(_ exe: String, _ args: [String]) async -> Int32 {
        await MainActor.run { self.appendLog("$ \((exe as NSString).lastPathComponent) \(args.last ?? "")") }
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            p.environment = env

            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let splitter = LineSplitter { line in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(line) } }
            }
            let reader = pipe.fileHandleForReading
            reader.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { splitter.feed(d) }
            }
            p.terminationHandler = { proc in
                reader.readabilityHandler = nil
                splitter.feed(reader.readDataToEndOfFile(), flush: true)
                // ať se poslední řádky (FILE …) zpracují dřív než výsledek
                DispatchQueue.main.async { cont.resume(returning: proc.terminationStatus) }
            }
            do {
                try p.run()
                box.process = p
            } catch {
                splitter.feed(Data("Chyba spuštění: \(error.localizedDescription)".utf8), flush: true)
                cont.resume(returning: -1)
            }
        }
    }
}
