// =============================================================================
//  CourtScoreApp.swift — iPhone remote for the CourtScore LED scoreboard
//
//  One file: Bluetooth link, board state, and the SwiftUI screens for
//  Tennis, Softball and Soccer, plus brightness / volume / mute / names.
//
//  The board keeps the score and announces it. The phone sends what happened
//  ({"cmd":"point","p":0}, {"cmd":"strike"}, {"cmd":"goal","team":1} …) and shows
//  the state the board sends back, so phone and board can never disagree.
//
//  Xcode setup
//    1. File > New > Project > iOS App (SwiftUI). Target iOS 17 or later.
//    2. Delete the generated ContentView.swift and <Name>App.swift, add this file.
//    3. Target > Info: add  "Privacy - Bluetooth Always Usage Description"
//       (NSBluetoothAlwaysUsageDescription) = "Connects to the court scoreboard".
//    4. Optional: Signing & Capabilities > + Background Modes > "Uses Bluetooth LE
//       accessories", so the link survives the phone being locked in your bag.
//    5. Run on a real iPhone (the Simulator has no Bluetooth).
// =============================================================================
import SwiftUI
import UIKit
@preconcurrency import CoreBluetooth

// MARK: - Protocol -------------------------------------------------------------

enum CourtUUID {
    static let service = CBUUID(string: "7A1E0001-5C3B-4F7A-9E2D-1A2B3C4D5E6F")
    static let command = CBUUID(string: "7A1E0002-5C3B-4F7A-9E2D-1A2B3C4D5E6F")
    static let state   = CBUUID(string: "7A1E0003-5C3B-4F7A-9E2D-1A2B3C4D5E6F")
}

enum Sport: String, CaseIterable, Identifiable {
    case tennis, softball, soccer
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var nameLength: Int { self == .tennis ? 4 : 3 }
    var sideLabels: (String, String) {
        switch self {
        case .tennis:   return ("Player 1", "Player 2")
        case .softball: return ("Visitors", "Home")
        case .soccer:   return ("Home", "Away")
        }
    }
}

/// The JSON the board publishes after every change. Keys are short to fit one BLE packet.
struct BoardState: Decodable, Equatable {
    // common
    var scr: String?          // "menu", "game", "gamemenu", "adjust"
    var game: String?
    var bri: Int?
    var vol: Int?
    var mute: Bool?
    var n: [String]?          // player / team names
    // tennis
    var sets: [[Int]]?
    var pts: [String]?
    var srv: Int?
    var tb: Bool?
    var done: Bool?
    // softball
    var inn: [[Int]]?
    var i: Int?               // inning
    var h: String?            // "top" / "bot"
    var b: Int?
    var s: Int?
    var o: Int?
    var fin: Bool?
    var max: Int?             // scheduled innings
    // soccer
    var sc: [Int]?
    var half: Int?
    var len: Int?             // minutes per half
    var add: Int?             // added minutes
    var secs: Int?            // match clock when this state was sent
    var run: Bool?
    var end: Bool?

    var sport: Sport? { game.flatMap(Sport.init(rawValue:)) }
    func name(_ i: Int) -> String { n?[safe: i] ?? (i == 0 ? "HOME" : "AWAY") }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

enum Haptics {
    static func tap()   { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - Bluetooth --------------------------------------------------------------

@MainActor
final class Board: NSObject, ObservableObject {
    enum Link: Equatable { case bluetoothOff, scanning, connecting, connected }

    @Published private(set) var link: Link = .bluetoothOff
    @Published private(set) var state = BoardState()
    @Published private(set) var stateTime = Date()      // when `state` arrived (for the soccer clock)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var stateChar: CBCharacteristic?
    private var awaitingRead = false
    private let savedIDKey = "CourtScoreBoardID"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Send one command, e.g. send("point", ["p": 0]).
    func send(_ cmd: String, _ extra: [String: Any] = [:]) {
        var body = extra
        body["cmd"] = cmd
        guard link == .connected, let p = peripheral, let c = commandChar,
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            Haptics.error(); return
        }
        p.writeValue(data, for: c, type: .withResponse)
        Haptics.tap()
    }

    /// Drop the remembered board and look for any CourtScore nearby.
    func findAnotherBoard() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        UserDefaults.standard.removeObject(forKey: savedIDKey)
        peripheral = nil; commandChar = nil; stateChar = nil
        scan()
    }

    // ---- internals ----
    private func scan() {
        guard central.state == .poweredOn else { return }
        link = .scanning
        central.scanForPeripherals(withServices: [CourtUUID.service])
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        link = .connecting
        central.connect(p)            // waits patiently if the board is off or out of range
    }

    fileprivate func powerChanged(_ s: CBManagerState) {
        guard s == .poweredOn else { link = .bluetoothOff; return }
        if let id = UserDefaults.standard.string(forKey: savedIDKey).flatMap(UUID.init(uuidString:)),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        }
        scan()                        // also scan, in case the remembered board is gone
    }

    fileprivate func discovered(_ p: CBPeripheral) {
        guard link != .connected else { return }
        central.stopScan()
        if peripheral?.identifier != p.identifier { connect(p) }
    }

    fileprivate func didConnect(_ p: CBPeripheral) {
        central.stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedIDKey)
        p.discoverServices([CourtUUID.service])
    }

    fileprivate func didDisconnect(_ p: CBPeripheral) {
        commandChar = nil; stateChar = nil
        link = .connecting
        central.connect(p)            // reconnects by itself when back in range
    }

    fileprivate func foundServices(_ p: CBPeripheral) {
        guard let svc = p.services?.first(where: { $0.uuid == CourtUUID.service }) else { return }
        p.discoverCharacteristics([CourtUUID.command, CourtUUID.state], for: svc)
    }

    fileprivate func foundCharacteristics(_ p: CBPeripheral, _ svc: CBService) {
        for ch in svc.characteristics ?? [] {
            if ch.uuid == CourtUUID.command { commandChar = ch }
            if ch.uuid == CourtUUID.state {
                stateChar = ch
                p.setNotifyValue(true, for: ch)
                awaitingRead = true
                p.readValue(for: ch)  // current score straight away
            }
        }
        if commandChar != nil { link = .connected }
    }

    fileprivate func received(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        guard ch.uuid == CourtUUID.state, let data = ch.value else { return }
        let wasRead = awaitingRead
        awaitingRead = false
        if let s = try? JSONDecoder().decode(BoardState.self, from: data) {
            state = s
            stateTime = Date()
        } else if !wasRead {
            // A long state (e.g. many innings) can be cut off in a notification.
            // A read always returns the whole value, so fetch it that way.
            awaitingRead = true
            p.readValue(for: ch)
        }
    }
}

extension Board: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let s = c.state
        MainActor.assumeIsolated { powerChanged(s) }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi: NSNumber) {
        MainActor.assumeIsolated { discovered(p) }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated { didConnect(p) }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { didDisconnect(p) }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { didDisconnect(p) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { foundServices(p) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        MainActor.assumeIsolated { foundCharacteristics(p, svc) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { received(p, ch) }
    }
}

// MARK: - App ----------------------------------------------------------------------

@main
struct CourtScoreApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var board = Board()
    @State private var sport: Sport = .tennis
    @State private var showSettings = false
    @State private var showNames = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    LinkBanner(board: board)

                    Picker("Game", selection: $sport) {
                        ForEach(Sport.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Group {
                        switch sport {
                        case .tennis:   TennisPanel(board: board)
                        case .softball: SoftballPanel(board: board)
                        case .soccer:   SoccerPanel(board: board)
                        }
                    }
                    .disabled(board.link != .connected)
                    .opacity(board.link == .connected ? 1 : 0.5)
                }
                .padding()
            }
            .navigationTitle("CourtScore")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showNames = true } label: { Image(systemName: "person.2") }
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsSheet(board: board) }
            .sheet(isPresented: $showNames) { NamesSheet(board: board, sport: sport) }
        }
        .preferredColorScheme(.dark)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }   // keep the screen on mid-match
        // Picking a tab switches the board; the board switching (wheel menu) moves the tab.
        .onChange(of: sport) { _, new in
            if board.state.sport != new { board.send("game", ["name": new.rawValue]) }
        }
        .onChange(of: board.state.game) { _, _ in
            if let s = board.state.sport, s != sport { sport = s }
        }
    }
}

// MARK: - Shared pieces ------------------------------------------------------------

struct LinkBanner: View {
    @ObservedObject var board: Board
    private var text: String {
        switch board.link {
        case .bluetoothOff: return "Bluetooth is off"
        case .scanning:     return "Looking for the scoreboard…"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected to CourtScore"
        }
    }
    private var color: Color {
        switch board.link {
        case .bluetoothOff: return .red
        case .scanning, .connecting: return .orange
        case .connected: return .green
        }
    }
    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.subheadline)
            Spacer()
            if board.link == .connected, board.state.scr != "game" {
                Text("Board is in its menu").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The black "LED" card at the top of each game.
struct ScoreCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 10) { content }
            .font(.system(.title2, design: .monospaced).bold())
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.gray.opacity(0.4), lineWidth: 2))
    }
}

struct ActionButton: View {
    let title: String
    var icon: String? = nil
    var color: Color = .gray
    var tall = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                Text(title).lineLimit(1).minimumScaleFactor(0.6)
            }
            .font(tall ? .title2.bold() : .headline)
            .frame(maxWidth: .infinity, minHeight: tall ? 90 : 48)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
    }
}

/// Undo + New with a confirmation, used by every game.
struct UndoNewRow: View {
    @ObservedObject var board: Board
    let newTitle: String
    @State private var confirmNew = false
    var body: some View {
        HStack(spacing: 10) {
            ActionButton(title: "Undo", icon: "arrow.uturn.backward") { board.send("undo") }
            ActionButton(title: newTitle, icon: "arrow.clockwise", color: .red.opacity(0.7)) { confirmNew = true }
        }
        .confirmationDialog("Start a new \(newTitle.lowercased())? The current score is cleared.",
                            isPresented: $confirmNew, titleVisibility: .visible) {
            Button(newTitle, role: .destructive) { board.send("new") }
        }
    }
}

// MARK: - Tennis -------------------------------------------------------------------

struct TennisPanel: View {
    @ObservedObject var board: Board

    var body: some View {
        let s = board.state.sport == .tennis ? board.state : BoardState()
        let sets = Array((s.sets ?? [[0, 0]]).suffix(3))
        VStack(spacing: 14) {
            ScoreCard {
                ForEach(0..<2, id: \.self) { p in
                    HStack(spacing: 12) {
                        Circle().fill(.yellow).frame(width: 9, height: 9)
                            .opacity(s.done != true && (s.srv ?? 1) == p + 1 ? 1 : 0)
                        Text(s.name(p)).foregroundStyle(.white)
                        Spacer()
                        ForEach(Array(sets.enumerated()), id: \.offset) { i, games in
                            Text("\(games[safe: p] ?? 0)")
                                .foregroundStyle(i == sets.count - 1 && s.done != true ? .green : .blue)
                        }
                        Text(s.done == true ? "" : (s.pts?[safe: p] ?? "0"))
                            .foregroundStyle(.orange)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                if s.tb == true { Text("TIEBREAK").font(.caption.bold()).foregroundStyle(.yellow) }
                if s.done == true { Text("MATCH OVER").font(.caption.bold()).foregroundStyle(.yellow) }
            }

            HStack(spacing: 10) {
                ActionButton(title: s.name(0), icon: "plus.circle.fill", color: .green, tall: true) {
                    board.send("point", ["p": 0])
                }
                ActionButton(title: s.name(1), icon: "plus.circle.fill", color: .blue, tall: true) {
                    board.send("point", ["p": 1])
                }
            }
            Text("Tap the player who won the point").font(.caption).foregroundStyle(.secondary)

            UndoNewRow(board: board, newTitle: "New Match")

            Menu {
                Button("Best of 3 sets") { board.send("bestof", ["n": 3]) }
                Button("Best of 5 sets") { board.send("bestof", ["n": 5]) }
            } label: {
                Label("Match format", systemImage: "list.number").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Softball -----------------------------------------------------------------

struct SoftballPanel: View {
    @ObservedObject var board: Board

    var body: some View {
        let s = board.state.sport == .softball ? board.state : BoardState()
        let inn = s.inn ?? [[0], []]
        let inning = s.i ?? 1
        let cols = Swift.max(s.max ?? 5, inning)
        let totals = inn.map { $0.reduce(0, +) }

        VStack(spacing: 14) {
            ScoreCard {
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("").frame(width: 56)
                            ForEach(1...cols, id: \.self) { n in
                                Text("\(n)").font(.caption.monospaced())
                                    .foregroundStyle(n == inning && s.fin != true ? .yellow : .gray)
                            }
                            Text("R").font(.caption.monospaced().bold()).foregroundStyle(.gray)
                        }
                        ForEach(0..<2, id: \.self) { t in
                            GridRow {
                                HStack(spacing: 4) {
                                    Circle().fill(.yellow).frame(width: 6, height: 6)
                                        .opacity(s.fin != true && (s.h == "bot") == (t == 1) ? 1 : 0)
                                    Text(s.name(t)).foregroundStyle(.white)
                                }
                                .frame(width: 56, alignment: .leading)
                                ForEach(0..<cols, id: \.self) { k in
                                    Text(inn[safe: t]?[safe: k].map { "\($0)" } ?? "")
                                        .foregroundStyle(k + 1 == inning && (s.h == "bot") == (t == 1) ? .yellow : .white)
                                }
                                Text("\(totals[safe: t] ?? 0)").foregroundStyle(.red)
                            }
                        }
                    }
                    .font(.system(.title3, design: .monospaced).bold())
                }
                Divider().overlay(Color.gray)
                HStack {
                    Text(s.fin == true ? "FINAL" : "\(s.h == "bot" ? "▼" : "▲") \(inning)")
                        .foregroundStyle(.yellow)
                    Spacer()
                    CountLights(label: "B", count: s.b ?? 0, max: 3, color: .green)
                    CountLights(label: "S", count: s.s ?? 0, max: 2, color: .red)
                    CountLights(label: "O", count: s.o ?? 0, max: 2, color: .red)
                }
                .font(.system(.headline, design: .monospaced))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ActionButton(title: "Ball",   color: .green)  { board.send("ball") }
                ActionButton(title: "Strike", color: .red)    { board.send("strike") }
                ActionButton(title: "Foul",   color: .orange) { board.send("foul") }
                ActionButton(title: "Out",    color: .gray)   { board.send("out") }
                ActionButton(title: "Hit",    color: .teal)   { board.send("hit") }
                ActionButton(title: "Run +1", color: .blue)   { board.send("run") }
            }

            UndoNewRow(board: board, newTitle: "New Game")

            Menu {
                ForEach([3, 5, 7, 9], id: \.self) { n in
                    Button("\(n) innings") { board.send("innings", ["n": n]) }
                }
            } label: {
                Label("Innings: \(s.max ?? 5)", systemImage: "number").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct CountLights: View {
    let label: String
    let count: Int
    let max: Int
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.white)
            ForEach(0..<max, id: \.self) { i in
                Circle().fill(i < count ? color : color.opacity(0.2)).frame(width: 12, height: 12)
            }
        }
        .padding(.leading, 6)
    }
}

// MARK: - Soccer -------------------------------------------------------------------

struct SoccerPanel: View {
    @ObservedObject var board: Board
    @State private var confirmHalf = false

    var body: some View {
        let s = board.state.sport == .soccer ? board.state : BoardState()
        let score = s.sc ?? [0, 0]
        let running = s.run ?? false
        let ended = s.end ?? false
        let half = s.half ?? 1
        let len = s.len ?? 45

        VStack(spacing: 14) {
            ScoreCard {
                Text(ended ? (half == 1 ? "HALF TIME" : "FULL TIME") : (half == 1 ? "1ST HALF" : "2ND HALF"))
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(ended ? .red : .gray)
                HStack {
                    VStack { Text(s.name(0)).font(.headline.monospaced()); Text("\(score[safe: 0] ?? 0)").font(.system(size: 48, weight: .bold, design: .monospaced)).foregroundStyle(.red) }
                        .frame(maxWidth: .infinity)
                    SoccerClock(state: s, stateTime: board.stateTime)
                    VStack { Text(s.name(1)).font(.headline.monospaced()); Text("\(score[safe: 1] ?? 0)").font(.system(size: 48, weight: .bold, design: .monospaced)).foregroundStyle(.red) }
                        .frame(maxWidth: .infinity)
                }
                if let add = s.add, add > 0 {
                    Text("+\(add) MIN ADDED").font(.caption.monospaced()).foregroundStyle(.orange)
                }
            }

            HStack(spacing: 10) {
                ActionButton(title: "Goal \(s.name(0))", icon: "soccerball", color: .green, tall: true) {
                    board.send("goal", ["team": 0])
                }
                ActionButton(title: "Goal \(s.name(1))", icon: "soccerball", color: .blue, tall: true) {
                    board.send("goal", ["team": 1])
                }
            }

            HStack(spacing: 10) {
                ActionButton(title: running ? "Pause" : "Start",
                             icon: running ? "pause.fill" : "play.fill",
                             color: running ? .orange : .green) {
                    board.send("clock", ["act": running ? "pause" : "start"])
                }
                .disabled(ended)
                ActionButton(title: "2nd Half", icon: "forward.end.fill", color: .indigo) { confirmHalf = true }
                    .disabled(half != 1)
            }
            .confirmationDialog("Start the second half? The clock resets to \(len):00.",
                                isPresented: $confirmHalf, titleVisibility: .visible) {
                Button("Start 2nd Half") { board.send("nexthalf") }
            }

            UndoNewRow(board: board, newTitle: "New Match")

            HStack(spacing: 10) {
                Menu {
                    ForEach([20, 30, 45], id: \.self) { m in
                        Button("\(m) minute halves") { board.send("halflen", ["min": m]) }
                    }
                } label: {
                    Label("Halves: \(len) min", systemImage: "timer").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Stepper("Added \(s.add ?? 0)′",
                        onIncrement: { board.send("added", ["min": Swift.min((s.add ?? 0) + 1, 15)]) },
                        onDecrement: { board.send("added", ["min": Swift.max((s.add ?? 0) - 1, 0)]) })
                    .font(.subheadline)
            }
        }
    }
}

/// Ticks locally between updates; the board stays the official clock.
struct SoccerClock: View {
    let state: BoardState
    let stateTime: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let running = state.run ?? false
            let live = running ? Int(ctx.date.timeIntervalSince(stateTime)) : 0
            let secs = (state.secs ?? 0) + Swift.max(0, live)
            let regEnd = (state.half ?? 1) * (state.len ?? 45) * 60
            let color: Color = (state.end ?? false) ? .red
                : secs >= regEnd ? .orange
                : running ? .white : .yellow
            Text(String(format: "%02d:%02d", secs / 60, secs % 60))
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Sheets -------------------------------------------------------------------

struct SettingsSheet: View {
    @ObservedObject var board: Board
    @Environment(\.dismiss) private var dismiss
    @State private var brightness = 60.0
    @State private var volume = 70.0
    @State private var soundOn = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    LabeledContent("Brightness", value: "\(Int(brightness))%")
                    Slider(value: $brightness, in: 5...100, step: 5) { editing in
                        if !editing { board.send("bright", ["v": Int(brightness)]) }
                    }
                }
                Section("Announcer") {
                    Toggle("Sound", isOn: $soundOn)
                        .onChange(of: soundOn) { _, on in
                            if on == (board.state.mute ?? false) { board.send("mute", ["on": !on]) }
                        }
                    LabeledContent("Volume", value: "\(Int(volume))%")
                    Slider(value: $volume, in: 0...100, step: 5) { editing in
                        if !editing { board.send("vol", ["v": Int(volume)]) }   // board beeps at the new level
                    }
                }
                Section("Board") {
                    Button("Show main menu on the board") { board.send("menu") }
                    Button("Find a different scoreboard", role: .destructive) { board.findAnotherBoard() }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                brightness = Double(board.state.bri ?? 60)
                volume = Double(board.state.vol ?? 70)
                soundOn = !(board.state.mute ?? false)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct NamesSheet: View {
    @ObservedObject var board: Board
    let sport: Sport
    @Environment(\.dismiss) private var dismiss
    @State private var a = ""
    @State private var b = ""

    var body: some View {
        let labels = sport.sideLabels
        NavigationStack {
            Form {
                Section {
                    TextField(labels.0, text: $a).textInputAutocapitalization(.characters)
                    TextField(labels.1, text: $b).textInputAutocapitalization(.characters)
                } footer: {
                    Text("Up to \(sport.nameLength) letters, as shown on the board. For spoken names, add clips with make_voice_clips.py (--name / --team).")
                }
            }
            .navigationTitle("\(sport.title) names")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        board.send("names", ["game": sport.rawValue, "a": a, "b": b])
                        dismiss()
                    }
                    .disabled(a.isEmpty && b.isEmpty)
                }
            }
            .onAppear {
                if board.state.sport == sport { a = board.state.name(0); b = board.state.name(1) }
            }
            .onChange(of: a) { _, v in a = clean(v) }
            .onChange(of: b) { _, v in b = clean(v) }
        }
        .presentationDetents([.medium])
    }

    private func clean(_ v: String) -> String {
        String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(sport.nameLength))
    }
}
