import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A remark attached to one part on one physical board.
struct PartNote: Codable, Equatable {
    enum Flag: String, Codable, CaseIterable {
        case none, outOfStock, rework, substituted

        var title: String {
            switch self {
            case .none: return "No flag"
            case .outOfStock: return "Out of stock"
            case .rework: return "Needs rework"
            case .substituted: return "Substituted"
            }
        }

        var symbol: String {
            switch self {
            case .none: return "flag"
            case .outOfStock: return "shippingbox"
            case .rework: return "wrench.and.screwdriver"
            case .substituted: return "arrow.triangle.swap"
            }
        }
    }

    var flag = Flag.none
    var text = ""
    var isEmpty: Bool { flag == .none && text.isEmpty }
}

/// Everything remembered about one board design between launches.
struct BoardState: Codable {
    /// Number of physical boards being built from this design.
    var unitCount = 1
    var unit = 0
    /// Per physical board: the references already soldered.
    var placed: [Set<String>] = [[]]
    /// Per physical board: notes by reference.
    var notes: [[String: PartNote]] = [[:]]
    /// Kit lines (value|footprint) already pulled from stock.
    var kitted: Set<String> = []
    var preset = OrderPreset.smdThenTHT
    /// Group keys in the order the user arranged them, if they did.
    var customOrder: [String]?
}

/// One line of the kitting list: a distinct part to pull from stock.
struct KitRow: Identifiable {
    let id: String
    let kind: String
    let value: String
    let sizeLabel: String?
    let footprint: String
    let refs: [String]

    /// One line per distinct value and footprint, grouped by kind of part.
    static func rows(for components: [Component]) -> [KitRow] {
        Dictionary(grouping: components) { $0.value + "|" + $0.footprint }.map { key, members in
            KitRow(id: key, kind: members[0].kindName, value: members[0].value, sizeLabel: members[0].sizeLabel,
                   footprint: members[0].footprint,
                   refs: members.map(\.ref).sorted { $0.compare($1, options: .numeric) == .orderedAscending })
        }.sorted {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            let order = $0.value.compare($1.value, options: .numeric)
            return order != .orderedSame ? order == .orderedAscending : $0.footprint < $1.footprint
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase {
        case empty
        case loading(String)
        case ready
        case failed(String)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case assemble = "Assemble", kit = "Kit", order = "Order", issues = "Notes"
        var id: String { rawValue }
    }

    // View state lives here rather than in `@State`: that needs Xcode's macro plugin, which the
    // Command Line Tools alone do not ship.
    @Published private(set) var phase: Phase = .empty
    @Published var tab = Tab.assemble
    @Published var search = ""
    @Published var confirmingReset = false
    @Published var showAll = false {
        didSet { refresh(focus: false) }
    }
    @Published var flatView = false {
        didSet { scene.setFlat(flatView) }
    }
    @Published private(set) var voiceOn = false
    @Published private(set) var voiceMessage: String?
    @Published private(set) var fillModels = UserDefaults.standard.object(forKey: "fillModels") as? Bool ?? true
    @Published private(set) var recents = UserDefaults.standard.stringArray(forKey: "recents")
        ?? [UserDefaults.standard.string(forKey: "lastBoard")].compactMap { $0 }  // from the first version

    @Published private(set) var boardName = ""
    @Published private(set) var plan = AssemblyPlan()
    @Published private(set) var state = BoardState()
    /// Index into `plan.steps`; equal to the step count when everything is placed.
    @Published private(set) var currentIndex = 0
    @Published private(set) var kitRows: [KitRow] = []
    @Published private(set) var warning: String?
    @Published private(set) var modelSummary = ""
    /// A pause shown when one stage is finished, before the next begins.
    @Published var checkpoint: String?
    @Published private(set) var testPlan: URL?

    let scene = BoardSceneController()
    private let voice = VoiceControl()
    private var byRef: [String: Component] = [:]
    private var components: [Component] = []
    private var boardURL: URL?
    private var loadedBoard: LoadedBoard?
    private var benchWindow: NSWindow?

    init() {
        // Plain keys step the guide, so a foot pedal or presenter clicker works too. They are handled
        // here rather than as button shortcuts so that typing in a text field is never hijacked.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKey(event) else { return event }
            return nil
        }
        voice.onCommand = { [weak self] command in
            switch command {
            case .next: self?.markPlaced()
            case .back: self?.back()
            case .skip: self?.skip()
            }
        }
        voice.onFailure = { [weak self] message in
            self?.voiceOn = false
            self?.voiceMessage = message
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isReady, tab == .assemble || NSApp.keyWindow === benchWindow,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let window = NSApp.keyWindow, window.attachedSheet == nil,
              !(window.firstResponder is NSTextView) else { return false }
        switch event.keyCode {
        case 49, 36, 76, 121: markPlaced()  // Space, Return, Enter, Page Down
        case 123, 116: back()  // Left arrow, Page Up
        case 124: skip()  // Right arrow
        default: return false
        }
        return true
    }

    var placed: Set<String> { state.placed[state.unit] }

    var current: Component? {
        currentIndex < plan.steps.count ? byRef[plan.steps[currentIndex]] : nil
    }

    var currentGroup: PartGroup? {
        currentIndex < plan.steps.count ? plan.groups[plan.groupOfStep[currentIndex]] : nil
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    func component(_ ref: String) -> Component? { byRef[ref] }

    // MARK: Opening boards

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open KiCad Board"
        if let type = UTType(filenameExtension: "kicad_pcb") { panel.allowedContentTypes = [type] }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func openInitialBoard() {
        guard case .empty = phase else { return }
        let argument = CommandLine.arguments.dropFirst().first { $0.hasSuffix(".kicad_pcb") }
        if let path = argument ?? recents.first, FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        }
    }

    func open(_ url: URL) {
        guard url.pathExtension == "kicad_pcb" else {
            phase = .failed("\(url.lastPathComponent) is not a .kicad_pcb board file.")
            return
        }
        phase = .loading("Exporting 3D model of \(url.lastPathComponent) with KiCad…")
        let fill = fillModels
        Task.detached(priority: .userInitiated) {
            do {
                let board = try BoardLoader.load(url: url, fillModels: fill)
                await MainActor.run { self.install(board) }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func install(_ board: LoadedBoard) {
        scene.install(board)
        loadedBoard = board
        boardURL = board.url
        boardName = board.url.deletingPathExtension().lastPathComponent
        components = board.components
        byRef = Dictionary(uniqueKeysWithValues: components.map { ($0.ref, $0) })
        warning = board.warning

        let drawn = components.filter(\.hasModel).count + board.filledModels
        modelSummary = board.model == nil ? "" :
            "\(drawn) of \(components.count) parts have a 3D model"
            + (board.filledModels > 0 ? " (\(board.filledModels) from KiCad's standard library)." : ".")

        state = loadState()
        buildKit()
        let directory = board.url.deletingLastPathComponent()
        testPlan = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .first { $0.uppercased().contains("TEST") && $0.lowercased().hasSuffix(".md") }
            .map { directory.appendingPathComponent($0) }

        recents = ([board.url.path] + recents.filter { $0 != board.url.path }).prefix(8).map { $0 }
        UserDefaults.standard.set(recents, forKey: "recents")
        checkpoint = nil
        search = ""
        // A fresh board starts on the kit list, so the right number of each part is on the bench first.
        tab = placed.isEmpty && state.kitted.count < kitRows.count ? .kit : .assemble
        phase = .ready
        rebuildPlan(animated: false)
        scene.setFlat(flatView, animated: false)
    }

    func setFillModels(_ on: Bool) {
        fillModels = on
        UserDefaults.standard.set(on, forKey: "fillModels")
        if let boardURL { open(boardURL) }
    }

    // MARK: Saved state

    private var stateKey: String { "state|" + (boardURL?.path ?? "") }

    private func loadState() -> BoardState {
        let defaults = UserDefaults.standard
        var loaded = BoardState()
        if let data = defaults.data(forKey: stateKey), let decoded = try? JSONDecoder().decode(BoardState.self, from: data) {
            loaded = decoded
        } else if let old = defaults.stringArray(forKey: "placed|" + (boardURL?.path ?? "")) {
            loaded.placed = [Set(old)]  // progress saved by the first version of the app
        }
        loaded.unitCount = max(1, loaded.unitCount)
        while loaded.placed.count < loaded.unitCount { loaded.placed.append([]) }
        while loaded.notes.count < loaded.unitCount { loaded.notes.append([:]) }
        loaded.unit = min(max(0, loaded.unit), loaded.unitCount - 1)
        loaded.placed = loaded.placed.map { $0.intersection(byRef.keys) }
        return loaded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: stateKey) }
    }

    // MARK: Stepping

    /// Marks the current part as placed and moves to the next unplaced one.
    func markPlaced() {
        guard isReady, currentIndex < plan.steps.count else { return }
        state.placed[state.unit].insert(plan.steps[currentIndex])
        advance()
    }

    /// Leaves the current part unplaced and moves on; it comes round again at the end.
    func skip() {
        guard isReady, currentIndex < plan.steps.count else { return }
        advance()
    }

    /// Returns to the previous part and marks it as not placed.
    func back() {
        guard isReady, currentIndex > 0 else { return }
        currentIndex -= 1
        state.placed[state.unit].remove(plan.steps[currentIndex])
        checkpoint = nil
        stepChanged()
    }

    func jump(to index: Int) {
        guard index < plan.steps.count else { return }
        currentIndex = index
        checkpoint = nil
        tab = .assemble
        stepChanged()
    }

    func jump(toRef ref: String) {
        if let index = plan.steps.firstIndex(of: ref) { jump(to: index) }
    }

    func resetProgress() {
        state.placed[state.unit] = []
        currentIndex = 0
        checkpoint = nil
        stepChanged()
    }

    func fitBoard() {
        scene.fitBoard()
    }

    private func advance() {
        let count = plan.steps.count
        let previousStage = currentGroup?.stage
        let order = Array((currentIndex + 1)..<count) + Array(0..<min(currentIndex + 1, count))
        currentIndex = order.first { !placed.contains(plan.steps[$0]) } ?? count

        // Pause for inspection once every part of a stage is on the board.
        checkpoint = nil
        if let previousStage, let next = currentGroup?.stage, next != previousStage {
            let stageDone = plan.groups.filter { $0.stage == previousStage }.allSatisfy { $0.refs.allSatisfy(placed.contains) }
            if stageDone {
                checkpoint = "\(previousStage.title) is finished. Inspect the joints and check for solder bridges before starting \(next.title)."
            }
        }
        stepChanged()
    }

    private func stepChanged() {
        save()
        refresh(focus: true)
    }

    private func refresh(focus: Bool, animated: Bool = true) {
        guard isReady else { return }
        let current = current
        // Identical parts still to come are shown faintly, so the right reel stays in hand.
        let upcoming = Set(currentGroup?.refs ?? []).subtracting(placed)
        scene.apply(placed: placed, current: current, upcoming: upcoming, showAll: showAll || current == nil)
        guard focus else { return }
        if let current {
            scene.focus(on: current, animated: animated)
        } else {
            scene.fitBoard(animated: animated)
        }
    }

    // MARK: Order

    private func rebuildPlan(animated: Bool = true) {
        plan = AssemblyPlan(components: components, preset: state.preset, customOrder: state.customOrder)
        currentIndex = plan.steps.firstIndex { !placed.contains($0) } ?? plan.steps.count
        save()
        refresh(focus: true, animated: animated)
    }

    func setPreset(_ preset: OrderPreset) {
        state.preset = preset
        state.customOrder = nil
        rebuildPlan()
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        var keys = plan.groups.map(\.key)
        keys.move(fromOffsets: source, toOffset: destination)
        state.customOrder = keys
        rebuildPlan()
    }

    func resetOrder() {
        state.customOrder = nil
        rebuildPlan()
    }

    // MARK: Physical boards

    func selectUnit(_ unit: Int) {
        guard unit >= 0, unit < state.unitCount else { return }
        state.unit = unit
        checkpoint = nil
        rebuildPlan()
    }

    func addUnit() {
        state.unitCount += 1
        state.placed.append([])
        state.notes.append([:])
        selectUnit(state.unitCount - 1)
    }

    /// Removes the highest-numbered board, which is only offered while it has no progress or notes.
    func removeLastUnit() {
        guard canRemoveLastUnit else { return }
        state.unitCount -= 1
        state.placed.removeLast()
        state.notes.removeLast()
        selectUnit(min(state.unit, state.unitCount - 1))
    }

    var canRemoveLastUnit: Bool {
        state.unitCount > 1 && state.placed[state.unitCount - 1].isEmpty && state.notes[state.unitCount - 1].isEmpty
    }

    // MARK: Kit

    private func buildKit() {
        kitRows = KitRow.rows(for: components)
    }

    /// Writes the guide for this board as a single web page that opens in any browser.
    func exportWebGuide() {
        guard isReady, let board = loadedBoard else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = boardName + " Assembly Guide.html"
        panel.allowedContentTypes = [.html]
        panel.message = "The page holds the whole guide and works on any device, without this app or KiCad."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try WebExport.write(board: board, plan: plan, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert()
            alert.messageText = "The web guide could not be saved."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// How many of this exact part (same value and footprint) one board needs, on both sides together.
    func boardQuantity(of part: Component) -> Int {
        kitRows.first { $0.id == part.value + "|" + part.footprint }?.refs.count ?? 1
    }

    func toggleKitted(_ id: String) {
        if !state.kitted.insert(id).inserted { state.kitted.remove(id) }
        save()
    }

    // MARK: Notes

    func note(for ref: String) -> PartNote {
        state.notes[state.unit][ref] ?? PartNote()
    }

    func setNote(_ note: PartNote, for ref: String) {
        state.notes[state.unit][ref] = note.isEmpty ? nil : note
        save()
    }

    /// Parts with a flag or note on the current board, in assembly order.
    var notedRefs: [String] {
        plan.steps.filter { state.notes[state.unit][$0] != nil }
    }

    // MARK: Hands-free, second screen, links

    func setVoice(_ on: Bool) {
        voiceMessage = nil
        voiceOn = on
        if on { voice.start() } else { voice.stop() }
    }

    /// Opens a clean, large-type window to put on a second display or an iPad used as one.
    func openBenchDisplay() {
        if benchWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Bench Display"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.fullScreenPrimary]
            window.contentView = NSHostingView(rootView: BenchView().environmentObject(self))
            window.center()
            benchWindow = window
        }
        benchWindow?.makeKeyAndOrderFront(nil)
    }

    func openDatasheet(_ part: Component) {
        if let text = part.datasheet, let url = URL(string: text), url.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(url)
        }
    }

    /// Looks up the part's top marking in the default browser's search engine.
    func searchMarking(_ part: Component) {
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: "\(part.partNumber ?? part.value) top marking code")]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    func openTestPlan() {
        if let testPlan { NSWorkspace.shared.open(testPlan) }
    }
}
