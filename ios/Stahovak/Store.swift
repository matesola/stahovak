import SwiftUI
import AVFoundation
import Photos

enum Mode: String { case video, audio, dropbox }

struct HistoryItem: Codable, Identifiable, Equatable {
    var id = UUID()
    let fileName: String
    let date: Date
    let platform: String
    /// true = soubor skončil v Dropboxu na Macu, v iPhonu není
    var remote: Bool? = nil
    var isRemote: Bool { remote == true }
    var url: URL { Store.folder.appendingPathComponent(fileName) }
    var exists: Bool { !isRemote && FileManager.default.fileExists(atPath: url.path) }
    var isVideo: Bool { ["mp4", "mov", "m4v", "webm"].contains(url.pathExtension.lowercased()) }
    var isAudio: Bool { ["mp3", "m4a", "aac", "wav", "opus"].contains(url.pathExtension.lowercased()) }
    var isPlayable: Bool { exists && (isVideo || isAudio) }
}

// MARK: Stahování s průběhem

/// URLSession download s delegátem kvůli procentům a rušení.
final class FileFetcher: NSObject, URLSessionDownloadDelegate {
    private var cont: CheckedContinuation<(file: URL, suggestedName: String?), Error>?
    private var task: URLSessionDownloadTask?
    private let onProgress: (Double?) -> Void

    init(onProgress: @escaping (Double?) -> Void) { self.onProgress = onProgress }

    func fetch(_ req: URLRequest) async throws -> (file: URL, suggestedName: String?) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600   // Mac most může chvíli stahovat, než pošle první bajt
        cfg.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            cont = c
            task = session.downloadTask(with: req)
            task?.resume()
        }
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        } else {
            onProgress(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // soubor z location zmizí po návratu, je třeba ho přesunout hned
        let http = downloadTask.response as? HTTPURLResponse
        if let code = http?.statusCode, !(200..<300).contains(code) {
            let body = (try? String(contentsOf: location, encoding: .utf8)) ?? ""
            cont?.resume(throwing: NSError(domain: "Stahovak", code: code,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) \(body.prefix(200))"]))
            cont = nil
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            cont?.resume(returning: (file: tmp, suggestedName: downloadTask.response?.suggestedFilename))
        } catch {
            cont?.resume(throwing: error)
        }
        cont = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { cont?.resume(throwing: error); cont = nil }
    }
}

// MARK: Stav aplikace

@MainActor
final class Store: ObservableObject {
    nonisolated static let folder: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    @Published var link = ""
    @Published var status = "Vlož odkaz"
    @Published var progress: Double?
    @Published var busy = false
    @Published var log = ""
    @Published var lastSaved: HistoryItem?

    @Published var history: [HistoryItem] = [] { didSet { save(history, "history") } }
    @Published var mode: Mode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var autoPhotos: Bool { didSet { d.set(autoPhotos, forKey: "autoPhotos") } }
    @Published var macHost: String { didSet { d.set(macHost, forKey: "macHost") } }
    @Published var macToken: String { didSet { d.set(macToken, forKey: "macToken") } }
    @Published var alwaysMac: Bool { didSet { d.set(alwaysMac, forKey: "alwaysMac") } }

    private let d = UserDefaults.standard
    private var fetcher: FileFetcher?
    private var job: Task<Void, Never>?
    private var cancelled = false
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    var macConfigured: Bool { !macHost.trimmingCharacters(in: .whitespaces).isEmpty }

    init() {
        mode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .video
        autoPhotos = d.object(forKey: "autoPhotos") as? Bool ?? true
        macHost = d.string(forKey: "macHost") ?? ""
        macToken = d.string(forKey: "macToken") ?? ""
        alwaysMac = d.bool(forKey: "alwaysMac")
        if let data = d.data(forKey: "history"),
           let h = try? JSONDecoder().decode([HistoryItem].self, from: data) { history = h }
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) }
    }

    func appendLog(_ s: String) {
        log += s + "\n"
        if log.count > 20_000 { log = String(log.suffix(15_000)) }
    }

    // MARK: Akce

    func handleIncoming(_ url: URL) {
        // stahovak://dl?u=<odkaz>  (pro Zkratku ze sdílecího menu)
        // stahovak://dl?u=<odkaz>&m=dropbox  (m je volitelné: video | audio | dropbox)
        guard url.scheme == "stahovak",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let u = items.first(where: { $0.name == "u" })?.value else { return }
        // běžící stahování nepřepisovat, jinak by odkaz v poli neseděl s tím, co se stahuje
        guard !busy else {
            status = "Ještě stahuju předchozí. Pošli to znovu za chvíli."
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        if let m = items.first(where: { $0.name == "m" })?.value, let mm = Mode(rawValue: m) { mode = mm }
        link = u
        start()
    }

    func cancel() {
        cancelled = true
        fetcher?.cancel()
        job?.cancel()
        status = "Zrušeno"
    }

    /// Dovolí dotáhnout stahování, když uživatel na chvíli odejde z appky (systém dá zhruba 30 s).
    private func beginBackground() {
        endBackground()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "Stahovak") { [weak self] in
            MainActor.assumeIsolated { self?.endBackground() }
        }
    }

    private func endBackground() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    func start() {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, !busy else { return }
        busy = true
        cancelled = false
        progress = nil
        log = ""
        lastSaved = nil

        beginBackground()
        job = Task {
            defer {
                busy = false
                job = nil
                endBackground()
            }
            let platform = Platform.detect(l)
            if mode == .dropbox {
                await toDropbox(l, platform: platform)
                return
            }
            do {
                let file: URL
                if let p = platform, p.hasNativeExtractor, !alwaysMac {
                    do {
                        file = try await native(l, platform: p)
                    } catch {
                        if cancelled { return }
                        appendLog("Přímo to nešlo: \(error.localizedDescription)")
                        guard macConfigured else { throw error }
                        file = try await viaMac(l)
                    }
                } else {
                    guard macConfigured else {
                        throw ExtractError.notFound(platform == .youtube
                            ? "YouTube jde jen přes Mac most. Nastav ho v ⚙︎."
                            : "Neznámý web. Zkus Mac most v ⚙︎.")
                    }
                    file = try await viaMac(l)
                }
                if cancelled { return }
                try await finish(file, platform: platform)
            } catch {
                if cancelled { return }
                status = error.localizedDescription
                appendLog("Chyba: \(error.localizedDescription)")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: Cesty

    private func native(_ l: String, platform: Platform) async throws -> URL {
        status = "Hledám video…"
        let media = try await Extractors.videoURL(for: l, platform: platform) { [weak self] s in
            Task { @MainActor in self?.appendLog(s) }
        }
        appendLog("Video: \(media.absoluteString.prefix(100))…")
        var req = URLRequest(url: media)
        req.setValue(Extractors.uaDesktop, forHTTPHeaderField: "User-Agent")
        let (tmp, _) = try await download(req, label: "Stahuju")

        let stamp = Self.stamp()
        var out = Self.uniqueURL(Self.folder.appendingPathComponent("\(platform.name.components(separatedBy: " ").first!) \(stamp).mp4"))
        try FileManager.default.moveItem(at: tmp, to: out)

        if mode == .audio {
            status = "Vytahuju zvuk…"
            out = try await extractAudio(out)
        }
        return out
    }

    /// MP3 do Dropboxu: stahuje i ukládá Mac, iPhone jen čeká na jméno souboru.
    private func toDropbox(_ l: String, platform: Platform?) async {
        guard macConfigured else {
            status = "Dropbox jde přes Mac most. Nastav ho v ⚙︎."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        var host = macHost.trimmingCharacters(in: .whitespaces)
        if !host.contains(":") { host += ":8765" }
        var comps = URLComponents(string: "http://\(host)/dropbox")!
        comps.queryItems = [.init(name: "u", value: l), .init(name: "t", value: macToken)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 900
        status = "Mac stahuje MP3 do Dropboxu…"
        progress = nil
        appendLog("Dropbox přes \(host)")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if cancelled { return }
            let body = String(decoding: data, as: UTF8.self)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ExtractError.notFound(body) }
            let item = HistoryItem(fileName: body, date: Date(),
                                   platform: platform?.rawValue ?? "WEB", remote: true)
            withAnimation(.spring(duration: 0.35)) { history.insert(item, at: 0) }
            progress = 1
            status = "V Dropboxu ✓ \(body)"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            if cancelled { return }
            status = error.localizedDescription
            appendLog("Chyba: \(error.localizedDescription)")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func viaMac(_ l: String) async throws -> URL {
        var host = macHost.trimmingCharacters(in: .whitespaces)
        if !host.contains(":") { host += ":8765" }
        var comps = URLComponents(string: "http://\(host)/dl")!
        comps.queryItems = [
            .init(name: "u", value: l),
            .init(name: "m", value: mode.rawValue),
            .init(name: "t", value: macToken),
        ]
        guard let url = comps.url else { throw ExtractError.badLink }
        appendLog("Mac most: \(host)")
        status = "Mac stahuje…"
        let (tmp, name) = try await download(URLRequest(url: url), label: "Přenáším z Macu")
        let fileName = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Mac \(Self.stamp()).\(mode == .audio ? "mp3" : "mp4")"
        let out = Self.uniqueURL(Self.folder.appendingPathComponent(fileName))
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    private func download(_ req: URLRequest, label: String) async throws -> (URL, String?) {
        let f = FileFetcher { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                self.progress = p
                if let p { self.status = "\(label)… \(Int(p * 100)) %" }
            }
        }
        fetcher = f
        defer { fetcher = nil }
        return try await f.fetch(req)
    }

    private func extractAudio(_ video: URL) async throws -> URL {
        let asset = AVURLAsset(url: video)
        guard let exp = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExtractError.notFound("Zvuk nejde vytáhnout.")
        }
        let out = video.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: out)
        exp.outputURL = out
        exp.outputFileType = .m4a
        await exp.export()
        guard exp.status == .completed else {
            throw exp.error ?? ExtractError.notFound("Export zvuku selhal.")
        }
        try? FileManager.default.removeItem(at: video)
        return out
    }

    private func finish(_ file: URL, platform: Platform?) async throws {
        let item = HistoryItem(fileName: file.lastPathComponent, date: Date(),
                               platform: platform?.rawValue ?? "WEB")
        withAnimation(.spring(duration: 0.35)) {
            history.insert(item, at: 0)
            if history.count > 100 { history.removeLast(history.count - 100) }
        }
        lastSaved = item
        progress = 1
        var msg = "Hotovo ✓"
        if autoPhotos, item.isVideo {
            do {
                try await saveToPhotos(file)
                msg += " Uloženo ve Fotkách."
            } catch {
                msg += " Do Fotek to nešlo: \(error.localizedDescription)"
            }
        }
        status = msg
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func saveToPhotos(_ file: URL) async throws {
        let st = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard st == .authorized || st == .limited else {
            throw ExtractError.notFound("Chybí povolení k Fotkám.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.shouldMoveFile = false
            req.addResource(with: .video, fileURL: file, options: opts)
        }
    }

    func delete(_ item: HistoryItem) {
        try? FileManager.default.removeItem(at: item.url)
        withAnimation { history.removeAll { $0.id == item.id } }
    }

    func clearHistory(deleteFiles: Bool) {
        if deleteFiles {
            for item in history where item.exists { try? FileManager.default.removeItem(at: item.url) }
        }
        withAnimation { history = [] }
    }

    func testMac() async -> String {
        var host = macHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return "Zadej adresu Macu." }
        if !host.contains(":") { host += ":8765" }
        guard let url = URL(string: "http://\(host)/ping?t=\(macToken)") else { return "Špatná adresa." }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data, as: UTF8.self)
            return code == 200 ? "Spojeno ✓ \(body)" : "HTTP \(code): \(body)"
        } catch {
            return "Nedostupné: \(error.localizedDescription)"
        }
    }

    // MARK: Pomocné

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    static func uniqueURL(_ u: URL) -> URL {
        var candidate = u
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = u.deletingLastPathComponent()
                .appendingPathComponent("\(u.deletingPathExtension().lastPathComponent) \(n).\(u.pathExtension)")
            n += 1
        }
        return candidate
    }
}
