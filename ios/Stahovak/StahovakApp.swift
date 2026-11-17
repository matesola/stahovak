import SwiftUI
import AVKit

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
    static let panel = Color(hex: 0x262321)
    static let cream = Color(hex: 0xF2EBDB)
    static let coral = Color(hex: 0xC8443A)
    static let warm = Color(hex: 0x8A8176)
}

extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

@main
struct StahovakApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onOpenURL { store.handleIncoming($0) }
        }
    }
}

// MARK: Hlavní obrazovka

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var showSettings = false
    @State private var showLog = false
    @State private var player: HistoryItem?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                urlSlot
                HStack {
                    ModeSwitch(mode: $store.mode)
                    Spacer()
                    if store.alwaysMac {
                        Label("MAC", systemImage: "desktopcomputer")
                            .font(.mono(10, .bold))
                            .foregroundStyle(Color.coral)
                    }
                }
                DownloadButton()
                Text(store.status)
                    .font(.mono(11))
                    .foregroundStyle(Color.warm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { showLog = true }
                TapePanel(player: $player)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(
            LinearGradient(colors: [Color(hex: 0x1C1A19), Color.ink], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .sheet(isPresented: $showLog) { LogView().environmentObject(store) }
        .fullScreenCover(item: $player) { item in
            VideoPlayer(player: AVPlayer(url: item.url))
                .ignoresSafeArea()
                .overlay(alignment: .topTrailing) {
                    Button { player = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.cream, Color.black.opacity(0.5))
                    }
                    .padding(20)
                }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 0) {
                    Text("STAHOVÁK")
                        .font(.system(size: 30, weight: .black))
                        .tracking(1.5)
                        .foregroundStyle(Color.cream)
                    Text(".")
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(Color.coral)
                }
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.warm)
                }
            }
            HStack(spacing: 6) {
                ForEach(Platform.allCases) { p in
                    let on = Platform.detect(store.link) == p
                    Text(p.rawValue)
                        .font(.mono(10, .bold))
                        .foregroundStyle(on ? Color.ink : Color.warm)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(on ? Color.coral : Color.clear))
                        .overlay(Capsule().strokeBorder(on ? Color.clear : Color.warm.opacity(0.35)))
                        .animation(.easeOut(duration: 0.2), value: on)
                }
            }
        }
    }

    private var urlSlot: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "link").foregroundStyle(Color.warm)
                TextField("", text: $store.link,
                          prompt: Text("Odkaz z YT, X, IG, FB, Threads").foregroundStyle(Color.warm.opacity(0.7)))
                    .font(.mono(14))
                    .foregroundStyle(Color.cream)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($fieldFocused)
                    .onSubmit { store.start() }
                if !store.link.isEmpty {
                    Button { store.link = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.warm)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.well))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))

            // PasteButton nečte schránku bez dovolení, takže nevyskakuje systémový dotaz
            PasteButton(payloadType: String.self) { strings in
                guard let s = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                store.link = s
                fieldFocused = false
                if Platform.detect(s) != nil { store.start() }
            }
            .buttonBorderShape(.capsule)
            .tint(Color.panel)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
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
            item(.audio, "ZVUK", "waveform")
            item(.dropbox, "DROPBOX", "shippingbox.fill")
        }
        .padding(3)
        .background(Capsule().fill(Color.well))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)))
    }

    private func item(_ m: Mode, _ title: String, _ icon: String) -> some View {
        let on = mode == m
        return Button {
            withAnimation(.spring(duration: 0.25)) { mode = m }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.mono(11, .bold))
            .foregroundStyle(on ? Color.ink : Color.warm)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background {
                if on { Capsule().fill(Color.cream).matchedGeometryEffect(id: "pill", in: ns) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct DownloadButton: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            store.busy ? store.cancel() : store.start()
        } label: {
            ZStack {
                Capsule().fill(store.busy ? Color.coral.opacity(0.22) : Color.coral)
                if store.busy {
                    TimelineView(.animation) { ctx in
                        GeometryReader { g in
                            if let p = store.progress {
                                Capsule()
                                    .fill(Color.coral)
                                    .frame(width: max(56, g.size.width * p))
                                    .animation(.easeOut(duration: 0.3), value: p)
                            } else {
                                let t = ctx.date.timeIntervalSinceReferenceDate
                                let phase = t.truncatingRemainder(dividingBy: 1.4) / 1.4
                                Capsule()
                                    .fill(LinearGradient(colors: [.clear, Color.coral, .clear],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: g.size.width * 0.35)
                                    .offset(x: g.size.width * 1.35 * phase - g.size.width * 0.35)
                            }
                        }
                    }
                    .clipShape(Capsule())
                }
                HStack(spacing: 10) {
                    Image(systemName: store.busy ? "xmark" : "arrow.down")
                        .font(.system(size: 15, weight: .black))
                    Text(label)
                        .font(.system(size: 16, weight: .black))
                        .tracking(2)
                }
                .foregroundStyle(Color.cream)
            }
            .frame(height: 58)
            .shadow(color: Color.coral.opacity(0.3), radius: 12, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(!store.busy && store.link.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var label: String {
        guard store.busy else { return store.mode == .dropbox ? "MP3 DO DROPBOXU" : "STÁHNOUT" }
        if let p = store.progress { return "ZRUŠIT · \(Int(p * 100)) %" }
        return "ZRUŠIT"
    }
}

struct TapePanel: View {
    @EnvironmentObject var store: Store
    @Binding var player: HistoryItem?
    @State private var confirmClear = false

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
                if !store.history.isEmpty {
                    Button("SMAZAT") { confirmClear = true }
                        .font(.mono(10, .bold))
                        .foregroundStyle(Color.warm)
                        .confirmationDialog("Smazat pásku?", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("Jen záznamy, soubory nechat") { store.clearHistory(deleteFiles: false) }
                            Button("Záznamy i soubory", role: .destructive) { store.clearHistory(deleteFiles: true) }
                            Button("Zrušit", role: .cancel) {}
                        } message: {
                            Text("Soubory jsou v aplikaci Soubory › Na iPhonu › Stahovák. Ve Fotkách zůstane všechno.")
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if store.history.isEmpty {
                Text("Zatím nic. Páska čeká.")
                    .font(.mono(12))
                    .foregroundStyle(Color.warm)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
            } else {
                ForEach(store.history) { item in
                    TapeRow(item: item, time: Self.time.string(from: item.date)) {
                        if item.isPlayable { player = item }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cream))
        .overlay(alignment: .top) { Perforation() }
    }
}

struct TapeRow: View {
    @EnvironmentObject var store: Store
    let item: HistoryItem
    let time: String
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(item.platform)
                .font(.mono(9, .bold))
                .foregroundStyle(Color.cream)
                .frame(width: 28, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(item.exists || item.isRemote ? Color.ink : Color.warm))
            Text(item.fileName)
                .font(.mono(12, .medium))
                .foregroundStyle(Color.ink.opacity(item.exists || item.isRemote ? 1 : 0.4))
                .strikethrough(!item.exists && !item.isRemote)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(time)
                .font(.mono(10))
                .foregroundStyle(Color.warm)
            if item.isRemote {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.coral)
            } else if item.exists {
                ShareLink(item: item.url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.coral)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.warm.opacity(0.25)).frame(height: 1).padding(.horizontal, 16)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .contextMenu {
            if item.exists {
                if item.isPlayable {
                    Button { onPlay() } label: { Label("Přehrát", systemImage: "play.fill") }
                }
                if item.isVideo {
                    Button {
                        Task { try? await store.saveToPhotos(item.url) }
                    } label: { Label("Uložit do Fotek", systemImage: "photo.on.rectangle") }
                }
                ShareLink(item: item.url) { Label("Sdílet", systemImage: "square.and.arrow.up") }
            }
            Button(role: .destructive) { store.delete(item) } label: {
                Label("Smazat", systemImage: "trash")
            }
        }
    }
}

struct Perforation: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 10
            while x < size.width - 6 {
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: -3, width: 6, height: 6)), with: .color(Color.ink))
                x += 14
            }
        }
        .frame(height: 4)
        .allowsHitTesting(false)
    }
}

// MARK: Nastavení

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Videa rovnou do Fotek", isOn: $store.autoPhotos)
                } footer: {
                    Text("Všechno zůstává i v aplikaci Soubory, složka Na iPhonu › Stahovák.")
                }

                Section {
                    TextField("např. MacBook-Pro.local", text: $store.macHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.mono(14))
                    TextField("Kód z Macu", text: $store.macToken)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.mono(14))
                    Toggle("Všechno posílat přes Mac", isOn: $store.alwaysMac)
                    Button {
                        testing = true
                        Task {
                            testResult = await store.testMac()
                            testing = false
                        }
                    } label: {
                        HStack {
                            Text("Otestovat spojení")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    if !testResult.isEmpty {
                        Text(testResult).font(.mono(12)).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Mac most")
                } footer: {
                    Text("YouTube a všechno, co iPhone sám nezvládne, stáhne Stahovák na Macu přes yt-dlp a pošle sem. Adresu a kód najdeš na Macu pod tlačítkem IPHONE. Funguje ve stejné Wi-Fi.")
                }

                Section {
                    Text("Zkratky › nová zkratka › Zobrazit ve sdílení (URL) › akce Otevřít URL s textem:\nstahovak://dl?u=[Vstup zkratky]\n\nRovnou MP3 do Dropboxu:\nstahovak://dl?m=dropbox&u=[Vstup zkratky]")
                        .font(.mono(12))
                        .textSelection(.enabled)
                } header: {
                    Text("Sdílecí menu")
                } footer: {
                    Text("Pak jde v Safari, IG nebo X zvolit Sdílet › Stahovák a stahování se rovnou spustí.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.ink)
            .navigationTitle("Nastavení")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { dismiss() } }
            }
        }
        .tint(Color.coral)
    }
}

struct LogView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(store.log.isEmpty ? "…" : store.log)
                    .font(.mono(11))
                    .foregroundStyle(Color.cream)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color.well)
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Zavřít") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(Color.coral)
    }
}
