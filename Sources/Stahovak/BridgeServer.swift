import Foundation
import Network
import SystemConfiguration
import SwiftUI

/// Malý HTTP server pro iPhone: GET /dl?u=<odkaz>&m=video|audio&t=<kód>
/// Mac stáhne přes yt-dlp do dočasné složky a pošle soubor zpátky.
@MainActor
final class BridgeServer: ObservableObject {
    static let port: UInt16 = 8765

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "bridgeEnabled")
            enabled ? start() : stop()
        }
    }
    @Published private(set) var running = false
    @Published private(set) var lastEvent = "Vypnuto"
    let token: String

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "stahovak.bridge")

    init() {
        let d = UserDefaults.standard
        if let t = d.string(forKey: "bridgeToken") {
            token = t
        } else {
            let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            token = String((0..<6).map { _ in chars.randomElement()! })
            d.set(token, forKey: "bridgeToken")
        }
        enabled = d.bool(forKey: "bridgeEnabled")
        if enabled { start() }
    }

    var hostName: String {
        if let n = SCDynamicStoreCopyLocalHostName(nil) as String? { return n + ".local" }
        return ProcessInfo.processInfo.hostName
    }

    var ipAddress: String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            // 169.254.x je samopřidělená adresa rozhraní bez sítě (USB, Thunderbolt), iPhone na ni nedosáhne
            guard !ip.hasPrefix("169.254.") else { continue }
            addr = ip
            if name == "en0" { break }
        }
        return addr
    }

    // MARK: Server

    private func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.service = NWListener.Service(name: "Stahovák", type: "_stahovak._tcp")
            l.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    switch st {
                    case .ready:
                        self?.running = true
                        self?.lastEvent = "Běží na portu \(Self.port)"
                    case .failed(let e):
                        self?.running = false
                        self?.lastEvent = "Chyba: \(e.localizedDescription)"
                        self?.listener = nil
                    case .cancelled:
                        self?.running = false
                    default: break
                    }
                }
            }
            let token = self.token
            l.newConnectionHandler = { [weak self] conn in
                let session = BridgeSession(conn: conn, token: token) { msg in
                    Task { @MainActor in self?.lastEvent = msg }
                }
                session.begin()
            }
            l.start(queue: queue)
            listener = l
        } catch {
            lastEvent = "Nejde spustit: \(error.localizedDescription)"
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        running = false
        lastEvent = "Vypnuto"
    }
}

/// Jedno spojení: přečte požadavek, stáhne, odešle soubor, zavře.
final class BridgeSession: @unchecked Sendable {
    private let conn: NWConnection
    private let token: String
    private let report: (String) -> Void
    private var buffer = Data()
    private static var retainedSessions: [ObjectIdentifier: BridgeSession] = [:]
    private static let lock = NSLock()

    init(conn: NWConnection, token: String, report: @escaping (String) -> Void) {
        self.conn = conn
        self.token = token
        self.report = report
    }

    func begin() {
        Self.lock.lock(); Self.retainedSessions[ObjectIdentifier(self)] = self; Self.lock.unlock()
        conn.start(queue: DispatchQueue(label: "stahovak.conn"))
        readHeader()
    }

    private func done() {
        conn.cancel()
        Self.lock.lock(); Self.retainedSessions[ObjectIdentifier(self)] = nil; Self.lock.unlock()
    }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                DispatchQueue.global(qos: .userInitiated).async { self.handle(head) }
            } else if isComplete || error != nil || buffer.count > 65_536 {
                done()
            } else {
                readHeader()
            }
        }
    }

    private func handle(_ head: String) {
        let firstLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let comps = URLComponents(string: "http://x" + parts[1]) else {
            return respond(400, "Bad request")
        }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                           uniquingKeysWith: { a, _ in a })
        guard q["t"]?.uppercased() == token else { return respond(403, "Spatny kod") }

        switch comps.path {
        case "/ping":
            respond(200, "Stahovak na Macu")
        case "/dl":
            guard let link = q["u"], let u = URL(string: link),
                  ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
                return respond(400, "Chybi odkaz")
            }
            let audio = q["m"] == "audio"
            report("iPhone: stahuju \(u.host ?? "")…")
            switch Self.runYtDlp(link, audio: audio) {
            case .success(let file):
                report("iPhone: posílám \(file.lastPathComponent)")
                sendFile(file)
            case .failure(let msg):
                report("iPhone: selhalo")
                respond(502, msg)
            }
        case "/dropbox":
            // YouTube (a cokoli dalšího) -> MP3 rovnou do Dropboxu na Macu, iPhonu jde jen potvrzení
            guard let link = q["u"], let u = URL(string: link),
                  ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
                return respond(400, "Chybi odkaz")
            }
            guard let dir = Self.dropboxTarget() else {
                return respond(500, "Na Macu nenasel Dropbox")
            }
            report("Dropbox: stahuju \(u.host ?? "")…")
            switch Self.runYtDlp(link, audio: true, into: dir) {
            case .success(let file):
                report("Dropbox: \(file.lastPathComponent)")
                respond(200, file.lastPathComponent)
            case .failure(let msg):
                report("Dropbox: selhalo")
                respond(502, msg)
            }
        default:
            respond(404, "Nic tu neni")
        }
    }

    // MARK: yt-dlp

    enum DLResult { case success(URL), failure(String) }

    private static func find(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Složka Dropbox/Stahovák. Cestu bere z ~/.dropbox/info.json, jinak zkusí obvyklá místa.
    static func dropboxTarget() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots: [URL] = []
        if let data = try? Data(contentsOf: home.appendingPathComponent(".dropbox/info.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["personal", "business"] {
                if let p = (obj[key] as? [String: Any])?["path"] as? String { roots.append(URL(fileURLWithPath: p)) }
            }
        }
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        if let items = try? fm.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil) {
            roots += items.filter { $0.lastPathComponent.hasPrefix("Dropbox") }
        }
        roots.append(home.appendingPathComponent("Dropbox"))
        let sub = UserDefaults.standard.string(forKey: "dropboxSubfolder") ?? "Stahovák"
        for r in roots where fm.fileExists(atPath: r.path) {
            let dir = r.appendingPathComponent(sub)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return nil
    }

    /// `into` = cílová složka (Dropbox); bez ní se stahuje do dočasné složky a soubor se pak posílá iPhonu.
    static func runYtDlp(_ link: String, audio: Bool, into target: URL? = nil) -> DLResult {
        guard let ytdlp = find("yt-dlp") else { return .failure("Na Macu chybi yt-dlp") }
        let tmp = target ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("stahovak-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // do Dropboxu čisté jméno (jen název videa), jinak s platformou a ID
        let template = target != nil
            ? "/%(title).120B.%(ext)s"
            : "/%(extractor_key)s - %(title).80B [%(id)s].%(ext)s"
        var args = ["--no-playlist", "--newline", "--no-overwrites",
                    "--print", "after_move:FILE %(filepath)s",
                    "-o", tmp.path + template]
        if let ff = find("ffmpeg") { args += ["--ffmpeg-location", ff] }
        if audio {
            // MP3 s názvem, interpretem a obalem z náhledu videa
            args += ["-x", "--audio-format", "mp3", "--audio-quality", "0",
                     "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg"]
        } else {
            // H.264 + AAC v MP4, ať to iPhone přehraje a vezmou to Fotky
            args += ["-f", "bv*[vcodec^=avc1]+ba[acodec^=mp4a]/bv*+ba/b",
                     "-S", "vcodec:h264,res,acodec:m4a", "--merge-output-format", "mp4"]
        }
        if let c = UserDefaults.standard.string(forKey: "cookies"), c != "none" {
            args += ["--cookies-from-browser", c]
        }
        args.append(link)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytdlp)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return .failure("yt-dlp nejde spustit") }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        let file = out.split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix("FILE ") }
            .map { URL(fileURLWithPath: String($0.dropFirst(5))) }
        if p.terminationStatus == 0, let f = file, FileManager.default.fileExists(atPath: f.path) {
            return .success(f)
        }
        let err = out.split(whereSeparator: \.isNewline).last { $0.contains("ERROR") } ?? "yt-dlp selhal"
        if target == nil { try? FileManager.default.removeItem(at: tmp) }
        return .failure(String(err))
    }

    // MARK: Odpovědi

    private func respond(_ code: Int, _ text: String) {
        let body = Data(text.utf8)
        let head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { [self] _ in done() })
    }

    private func sendFile(_ file: URL) {
        guard let fh = try? FileHandle(forReadingFrom: file),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int else {
            return respond(500, "Soubor nejde precist")
        }
        let name = file.lastPathComponent
        let ascii = name.unicodeScalars.map { $0.isASCII && $0 != "\"" ? String($0) : "_" }.joined()
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ascii
        let type = file.pathExtension.lowercased() == "mp3" ? "audio/mpeg" : "video/mp4"
        let head = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: \(type)\r\n" +
            "Content-Length: \(size)\r\n" +
            "Content-Disposition: attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)\r\n" +
            "Connection: close\r\n\r\n"

        let folder = file.deletingLastPathComponent()
        let cleanup = { [self] in
            try? fh.close()
            try? FileManager.default.removeItem(at: folder)
            done()
        }
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [self] err in
            if err != nil { return cleanup() }
            sendChunk(fh, cleanup: cleanup)
        })
    }

    private func sendChunk(_ fh: FileHandle, cleanup: @escaping () -> Void) {
        let chunk = (try? fh.read(upToCount: 1 << 20)) ?? nil
        guard let chunk, !chunk.isEmpty else { return cleanup() }
        conn.send(content: chunk, completion: .contentProcessed { [self] err in
            if err != nil { return cleanup() }
            sendChunk(fh, cleanup: cleanup)
        })
    }
}
