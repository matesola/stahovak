import SwiftUI
import AppKit

// MARK: Paleta (rodina DIGITCA)

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    static let ink = Color(hex: 0x171717)
    static let well = Color(hex: 0x0E0E0E)
    static let panel = Color(hex: 0x1F1D1C)
    static let cream = Color(hex: 0xF2EBDB)
    static let coral = Color(hex: 0xC8443A)
    static let warm = Color(hex: 0x8A8176)
}

extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: App

@main
struct StahovakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var dl = Downloader()
    @StateObject private var bridge = BridgeServer()

    var body: some Scene {
        WindowGroup("Stahovák") {
            ContentView()
                .environmentObject(dl)
                .environmentObject(bridge)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: Hlavní okno

struct ContentView: View {
    @EnvironmentObject var dl: Downloader
    @State private var dropTargeted = false
    @State private var showLog = false
    @State private var showBridge = false
    @EnvironmentObject var bridge: BridgeServer

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            urlSlot
            HStack(spacing: 12) {
                ModeSwitch(mode: $dl.mode)
                Spacer()
                cookiesMenu
            }
            DownloadButton()
            Text(dl.status)
                .font(.mono(11))
                .foregroundStyle(Color.warm)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            TapePanel()
            footer
        }
        .padding(.horizontal, 26)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(width: 620)
        .background(
            LinearGradient(colors: [Color(hex: 0x1C1A19), Color.ink],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            dl.url = u.absoluteString
            dl.start()
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear { dl.pasteFromClipboard(onlyIfSupported: true) }
    }

    // Logo + platformy

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 0) {
                Text("STAHOVÁK")
                    .font(.system(size: 26, weight: .black))
                    .tracking(2)
                    .foregroundStyle(Color.cream)
                Text(".")
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(Color.coral)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Platform.allCases) { p in
                    let on = Platform.detect(dl.url) == p
                    Text(p.rawValue)
                        .font(.mono(10, .bold))
                        .foregroundStyle(on ? Color.ink : Color.warm)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(on ? Color.coral : Color.clear)
                        )
                        .overlay(
                            Capsule().strokeBorder(on ? Color.clear : Color.warm.opacity(0.35), lineWidth: 1)
                        )
                        .animation(.easeOut(duration: 0.2), value: on)
                        .help(p.name)
                }
            }
        }
    }

    // Vstupní štěrbina

    private var urlSlot: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(dropTargeted ? Color.coral : Color.warm)
            TextField("", text: $dl.url,
                      prompt: Text("Vlož nebo přetáhni odkaz…").foregroundStyle(Color.warm.opacity(0.7)))
                .textFieldStyle(.plain)
                .font(.mono(14))
                .foregroundStyle(Color.cream)
                .onSubmit { dl.start() }
            if !dl.url.isEmpty {
                Button { dl.url = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.warm)
                }
                .buttonStyle(.plain)
            }
            Button { dl.pasteFromClipboard() } label: {
                Text("VLOŽIT")
                    .font(.mono(10, .bold))
                    .foregroundStyle(Color.cream)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.panel))
            }
            .buttonStyle(PressStyle())
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(Color.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(dropTargeted ? Color.coral : Color.white.opacity(0.06),
                              lineWidth: dropTargeted ? 2 : 1)
        )
        .shadow(color: dropTargeted ? Color.coral.opacity(0.45) : .clear, radius: 14)
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    private var cookiesMenu: some View {
        Menu {
            ForEach(CookieSource.allCases) { c in
                Button {
                    dl.cookies = c
                } label: {
                    if dl.cookies == c { Label(c.label, systemImage: "checkmark") } else { Text(c.label) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "key.fill")
                Text(dl.cookies.short)
            }
            .font(.mono(10, .bold))
            .foregroundStyle(dl.cookies == .none ? Color.warm : Color.cream)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("IG a FB často chtějí přihlášení. Vyber prohlížeč, kde jsi přihlášený.")
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { dl.chooseFolder() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(dl.outputDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { showBridge.toggle() } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(bridge.running ? Color.coral : Color.warm.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text("IPHONE")
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showBridge, arrowEdge: .bottom) { BridgeView().environmentObject(bridge) }
            Button("LOG") { showLog.toggle() }
                .buttonStyle(.plain)
                .popover(isPresented: $showLog, arrowEdge: .bottom) { LogView().environmentObject(dl) }
            Button("AKTUALIZOVAT NÁSTROJE") { dl.updateTools() }
                .buttonStyle(.plain)
                .disabled(dl.busy)
        }
        .font(.mono(10, .medium))
        .foregroundStyle(Color.warm)
    }
}

// MARK: Komponenty

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
    }
}

struct ModeSwitch: View {
    @Binding var mode: Mode
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            item(.video, "VIDEO", "film")
            item(.audio, "MP3", "waveform")
        }
        .padding(3)
        .background(Capsule().fill(Color.well))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)))
    }

    private func item(_ m: Mode, _ title: String, _ icon: String) -> some View {
        let on = mode == m
        return Button {
            withAnimation(.spring(duration: 0.25)) { mode = m }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.mono(11, .bold))
            .foregroundStyle(on ? Color.ink : Color.warm)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                if on {
                    Capsule().fill(Color.cream).matchedGeometryEffect(id: "pill", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Velké tlačítko, které se během stahování mění v progress bar.
struct DownloadButton: View {
    @EnvironmentObject var dl: Downloader
    @State private var hover = false

    var body: some View {
        Button {
            dl.busy ? dl.cancel() : dl.start()
        } label: {
            ZStack {
                Capsule().fill(dl.busy ? Color.coral.opacity(0.22) : Color.coral)
                if dl.busy {
                    TimelineView(.animation) { ctx in
                        GeometryReader { g in
                            if let p = dl.progress {
                                Capsule()
                                    .fill(Color.coral)
                                    .frame(width: max(52, g.size.width * p))
                                    .animation(.easeOut(duration: 0.3), value: p)
                            } else {
                                // neurčitý průběh: běžící světelný pruh
                                let t = ctx.date.timeIntervalSinceReferenceDate
                                let phase = (t.truncatingRemainder(dividingBy: 1.4)) / 1.4
                                Capsule()
                                    .fill(LinearGradient(colors: [.clear, Color.coral, .clear],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: g.size.width * 0.35)
                                    .offset(x: (g.size.width * 1.35) * phase - g.size.width * 0.35)
                            }
                        }
                    }
                    .clipShape(Capsule())
                }
                HStack(spacing: 10) {
                    Image(systemName: dl.busy ? "xmark" : "arrow.down")
                        .font(.system(size: 14, weight: .black))
                    Text(label)
                        .font(.system(size: 15, weight: .black))
                        .tracking(2)
                }
                .foregroundStyle(Color.cream)
            }
            .frame(height: 54)
            .shadow(color: Color.coral.opacity(hover && !dl.busy ? 0.55 : 0.25), radius: hover ? 18 : 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(!dl.busy && dl.url.trimmingCharacters(in: .whitespaces).isEmpty)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.2), value: hover)
    }

    private var label: String {
        guard dl.busy else { return "STÁHNOUT" }
        if let p = dl.progress { return "ZRUŠIT · \(Int(p * 100)) %" }
        return "ZRUŠIT"
    }
}

/// Historie stažených souborů jako krémová páska.
struct TapePanel: View {
    @EnvironmentObject var dl: Downloader

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d.M. HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PÁSKA")
                    .font(.mono(10, .bold))
                    .tracking(2)
                    .foregroundStyle(Color.warm)
                Spacer()
                if !dl.history.isEmpty {
                    Button("SMAZAT") { withAnimation { dl.clearHistory() } }
                        .buttonStyle(.plain)
                        .font(.mono(10, .bold))
                        .foregroundStyle(Color.warm)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if dl.history.isEmpty {
                Text("Zatím nic. Páska čeká.")
                    .font(.mono(12))
                    .foregroundStyle(Color.warm)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(dl.history) { item in
                            TapeRow(item: item, time: Self.time.string(from: item.date))
                        }
                    }
                }
                .frame(height: min(CGFloat(dl.history.count) * 34, 34 * 5))
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.cream)
        )
        .overlay(alignment: .top) { Perforation() }
    }
}

struct TapeRow: View {
    let item: HistoryItem
    let time: String
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Text(item.platform)
                .font(.mono(9, .bold))
                .foregroundStyle(Color.cream)
                .frame(width: 26, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(item.exists ? Color.ink : Color.warm))
            Text(item.url.lastPathComponent)
                .font(.mono(12, .medium))
                .foregroundStyle(Color.ink.opacity(item.exists ? 1 : 0.4))
                .strikethrough(!item.exists)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(time)
                .font(.mono(10))
                .foregroundStyle(Color.warm)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.coral)
                .opacity(hover && item.exists ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(hover ? Color.ink.opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.warm.opacity(0.25))
                .frame(height: 1)
                .padding(.horizontal, 16)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if item.exists { NSWorkspace.shared.open(item.url) } }
        .onTapGesture { if item.exists { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
        .help(item.exists ? "Klik: ve Finderu · Dvojklik: otevřít" : "Soubor už neexistuje")
    }
}

/// Perforace horní hrany pásky.
struct Perforation: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 14
            var x: CGFloat = 10
            while x < size.width - 6 {
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: -3, width: 6, height: 6)), with: .color(Color.ink))
                x += step
            }
        }
        .frame(height: 4)
        .allowsHitTesting(false)
    }
}

struct LogView: View {
    @EnvironmentObject var dl: Downloader
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(dl.log.isEmpty ? "…" : dl.log)
                    .font(.mono(11))
                    .foregroundStyle(Color.cream)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                Color.clear.frame(height: 1).id("end")
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(width: 560, height: 280)
        .background(Color.well)
    }
}

/// Nastavení mostu pro iPhone.
struct BridgeView: View {
    @EnvironmentObject var bridge: BridgeServer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $bridge.enabled) {
                Text("Stahovat pro iPhone")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.cream)
            }
            .toggleStyle(.switch)
            .tint(Color.coral)

            VStack(alignment: .leading, spacing: 6) {
                row("ADRESA", bridge.hostName)
                if let ip = bridge.ipAddress { row("NEBO IP", ip) }
                row("KÓD", bridge.token)
                row("DROPBOX", BridgeSession.dropboxTarget()?.path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "nenalezen")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.cream))

            Text(bridge.lastEvent)
                .font(.mono(10))
                .foregroundStyle(Color.warm)
            Text("Na iPhonu: ⚙︎ › Mac most › adresa a kód. Mac musí být ve stejné Wi-Fi a vzhůru.")
                .font(.system(size: 11))
                .foregroundStyle(Color.warm)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
        .background(Color.ink)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.mono(9, .bold)).foregroundStyle(Color.warm).frame(width: 56, alignment: .leading)
            Text(value).font(.mono(13, .bold)).foregroundStyle(Color.ink).textSelection(.enabled)
        }
    }
}
