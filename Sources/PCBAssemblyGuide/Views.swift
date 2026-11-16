import SceneKit
import SwiftUI
import UniformTypeIdentifiers

struct GuideApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("PCB Assembly Guide", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { model.openInitialBoard() }
                .onOpenURL { model.open($0) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Board…") { model.openPanel() }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(model.recents, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { model.open(URL(fileURLWithPath: path)) }
                    }
                }
                .disabled(model.recents.isEmpty)
                Divider()
                Button("Export Web Guide…") { model.exportWebGuide() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.isReady)
            }
            CommandGroup(before: .toolbar) {
                ForEach(Array(AppModel.Tab.allCases.enumerated()), id: \.element) { index, tab in
                    Button(tab.rawValue) { model.tab = tab }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                .disabled(!model.isReady)
                Divider()
                Toggle("Flat View", isOn: $model.flatView)
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(!model.isReady)
                Button("Bench Display") { model.openBenchDisplay() }
                    .keyboardShortcut("b")
                    .disabled(!model.isReady)
                Divider()
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .empty:
                StartView(message: nil)
            case .failed(let message):
                StartView(message: message)
            case .loading(let message):
                ProgressView(message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                GuideView()
            }
        }
        .frame(minWidth: 1080, minHeight: 660)
        .navigationTitle(model.boardName.isEmpty ? "PCB Assembly Guide" : model.boardName)
        .toolbar {
            if model.isReady {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $model.tab) {
                        ForEach(AppModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Assemble step by step, pull the kit, change the order, or review notes")
                }
            }
            ToolbarItemGroup {
                if model.isReady {
                    UnitMenu()
                    Toggle("Flat View", systemImage: "square.grid.3x3", isOn: $model.flatView)
                        .help("Flat top-down view, like the silkscreen drawing")
                    Button("Whole Board", systemImage: "arrow.up.left.and.arrow.down.right") { model.fitBoard() }
                        .help("Zoom out to the whole board")
                    Toggle("Show All Parts", systemImage: "eye", isOn: $model.showAll)
                        .help("Preview the fully assembled board")
                    Button("Bench Display", systemImage: "rectangle.on.rectangle") { model.openBenchDisplay() }
                        .help("Open a large-type window for a second screen or iPad")
                    Toggle("Voice", systemImage: "mic", isOn: Binding(get: { model.voiceOn }, set: { model.setVoice($0) }))
                        .help("Step by saying “next”, “back” or “skip”")
                    Menu("Options", systemImage: "gearshape") {
                        Toggle("Use Standard Models for Parts Without One",
                               isOn: Binding(get: { model.fillModels }, set: { model.setFillModels($0) }))
                        Divider()
                        Button("Clear Progress on This Board…") { model.confirmingReset = true }
                    }
                }
                Button("Open", systemImage: "folder") { model.openPanel() }
                    .help("Open a KiCad board")
            }
        }
        .confirmationDialog("Clear all progress for board \(model.state.unit + 1)?", isPresented: $model.confirmingReset) {
            Button("Clear Progress", role: .destructive) { model.resetProgress() }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url) } }
            }
            return true
        }
    }
}

/// Chooses which physical board is being built when several are made from one design.
private struct UnitMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu("Board \(model.state.unit + 1) of \(model.state.unitCount)") {
            ForEach(0..<model.state.unitCount, id: \.self) { unit in
                let done = model.state.placed[unit].count
                Button("Board \(unit + 1): \(done) of \(model.plan.steps.count) placed") { model.selectUnit(unit) }
            }
            Divider()
            Button("Add Another Board") { model.addUnit() }
            Button("Remove Board \(model.state.unitCount)") { model.removeLastUnit() }
                .disabled(!model.canRemoveLastUnit)
        }
        .help("Track each physical board separately")
    }
}

private struct StartView: View {
    @EnvironmentObject private var model: AppModel
    let message: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cpu")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Open a KiCad board to start assembling")
                .font(.title2)
            Text("Choose a .kicad_pcb file, or drop one on this window.")
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 520)
            }
            Button("Open Board…") { model.openPanel() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            if !model.recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.headline)
                    ForEach(model.recents, id: \.self) { path in
                        Button {
                            model.open(URL(fileURLWithPath: path))
                        } label: {
                            VStack(alignment: .leading) {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                Text(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GuideView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            switch model.tab {
            case .assemble:
                HStack(spacing: 0) {
                    SceneContainer(controller: model.scene, isPrimary: true) { model.jump(toRef: $0) }
                    Divider()
                    InfoPanel()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { ControlBar() }
            case .kit:
                KitView()
            case .order:
                OrderView()
            case .issues:
                NotesView()
            }
        }
    }
}

// MARK: 3D view

/// A SceneKit view that reports plain clicks (not drags) so parts can be picked.
final class PickingSCNView: SCNView {
    var onClick: ((CGPoint) -> Void)?
    private var downPoint: CGPoint?

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let downPoint, hypot(point.x - downPoint.x, point.y - downPoint.y) < 4 { onClick?(point) }
        super.mouseUp(with: event)
    }
}

/// The primary view owns the camera controls; secondary views (the bench display) mirror the same camera.
struct SceneContainer: NSViewRepresentable {
    let controller: BoardSceneController
    let isPrimary: Bool
    var onPick: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> PickingSCNView {
        let view = PickingSCNView()
        view.scene = controller.scene
        view.pointOfView = controller.cameraNode
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(white: 0.11, alpha: 1)
        view.onClick = { [weak view] point in
            if let view, let ref = controller.pick(at: point, in: view) { onPick(ref) }
        }
        if isPrimary {
            view.allowsCameraControl = true
            view.defaultCameraController.interactionMode = .orbitTurntable
            controller.view = view
        }
        return view
    }

    func updateNSView(_ view: PickingSCNView, context: Context) {}
}

// MARK: Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find R114, 10k, 0402…", text: $model.search)
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { model.search = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            if model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                StepList()
            } else {
                SearchResults()
            }
        }
    }
}

private struct StepRow: View {
    @EnvironmentObject private var model: AppModel
    let ref: String
    let index: Int
    var detail: String?

    var body: some View {
        let isCurrent = index == model.currentIndex
        let isPlaced = model.placed.contains(ref)
        let note = model.note(for: ref)
        HStack {
            Image(systemName: isCurrent ? "arrow.right.circle.fill" : isPlaced ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCurrent ? Color.orange : isPlaced ? Color.green : Color.secondary)
            Text(ref)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isPlaced && !isCurrent ? .secondary : .primary)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !note.isEmpty {
                Image(systemName: note.flag == .none ? "note.text" : note.flag.symbol)
                    .foregroundStyle(.yellow)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.jump(to: index) }
        .listRowBackground(isCurrent ? Color.orange.opacity(0.18) : Color.clear)
    }
}

private struct StepList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.plan.groups) { group in
                    Section {
                        ForEach(Array(group.refs.enumerated()), id: \.element) { offset, ref in
                            StepRow(ref: ref, index: group.firstStep + offset)
                                .id(ref)
                        }
                    } header: {
                        header(group)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: model.currentIndex) { _, index in
                guard index < model.plan.steps.count else { return }
                withAnimation { proxy.scrollTo(model.plan.steps[index], anchor: .center) }
            }
        }
    }

    private func header(_ group: PartGroup) -> some View {
        let done = group.refs.filter(model.placed.contains).count
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(group.value.isEmpty ? group.footprint : group.value)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(done)/\(group.refs.count)")
                    .monospacedDigit()
            }
            Text("\(group.stage.title) · \(group.sizeLabel ?? group.footprint)")
                .font(.caption)
                .lineLimit(1)
        }
    }
}

private struct SearchResults: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let query = model.search.trimmingCharacters(in: .whitespaces)
        let matches = model.plan.steps.enumerated().filter { _, ref in
            guard let part = model.component(ref) else { return false }
            return [part.ref, part.value, part.footprint].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        List {
            if matches.isEmpty {
                Text("No parts match “\(query)”.")
                    .foregroundStyle(.secondary)
            }
            ForEach(matches, id: \.element) { index, ref in
                let part = model.component(ref)
                StepRow(ref: ref, index: index,
                        detail: [part?.value, part?.sizeLabel].compactMap { $0 }.joined(separator: " · "))
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: Part details

private struct InfoPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let checkpoint = model.checkpoint {
                    CheckpointNote(text: checkpoint)
                }
                if let part = model.current, let group = model.currentGroup {
                    PartHeadline(part: part)
                    Text(part.footprint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Divider()
                    Label("\(part.isBottom ? "Bottom" : "Top") side · \(part.isTHT ? "through-hole" : "surface-mount")",
                          systemImage: part.isBottom ? "square.bottomhalf.filled" : "square.tophalf.filled")
                    PickCount(part: part, group: group)
                    JumperNote(part: part)
                    PolarityNote(part: part)
                    NetList(part: part)
                    MarkingNote(part: part)
                    Divider()
                    NoteEditor(ref: part.ref)
                } else {
                    Text("All parts placed")
                        .font(.title.bold())
                    Text("\(model.plan.steps.count) components on board \(model.state.unit + 1).")
                        .foregroundStyle(.secondary)
                    if model.testPlan != nil {
                        Button("Open Test Plan") { model.openTestPlan() }
                    }
                }
                if !model.modelSummary.isEmpty || model.warning != nil || model.voiceMessage != nil {
                    Divider()
                    ForEach([model.voiceMessage, model.warning, model.modelSummary].compactMap { $0 }.filter { !$0.isEmpty },
                            id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 340)
        .background(.regularMaterial)
    }
}

/// What to look for on the reel or bag: value first, then package size.
private struct PartHeadline: View {
    let part: Component

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(part.ref)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                Text(part.kindName)
                    .foregroundStyle(.secondary)
            }
            Text(part.value.isEmpty ? part.footprint : part.value)
                .font(.system(size: 46, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let size = part.sizeLabel {
                    Text(size)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(part.dimensions)
                        .font(.title3.weight(.medium))
                    if part.padCount > 2 {
                        Text("\(part.padCount) pins")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// How many of this part to take out before starting the run of identical parts.
private struct PickCount: View {
    @EnvironmentObject private var model: AppModel
    let part: Component
    let group: PartGroup

    var body: some View {
        let left = group.refs.filter { !model.placed.contains($0) }.count
        let onBoard = model.boardQuantity(of: part)
        HStack(alignment: .center, spacing: 12) {
            Text("×\(group.refs.count)")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(group.refs.count == 1 ? "Take 1 of these" : "Take \(group.refs.count) of these")
                    .font(.headline)
                Text("\(left) still to place"
                     + (onBoard > group.refs.count ? " · \(onBoard) on the whole board" : ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct Callout<Content: View>: View {
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.7)))
    }
}

private struct CheckpointNote: View {
    @EnvironmentObject private var model: AppModel
    let text: String

    var body: some View {
        Callout(color: .yellow) {
            Label("Checkpoint", systemImage: "pause.circle.fill")
                .font(.headline)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.testPlan != nil {
                    Button("Open Test Plan") { model.openTestPlan() }
                }
                Button("Continue") { model.checkpoint = nil }
            }
        }
    }
}

/// Says which two pads of a multi-pad jumper footprint the link goes across.
private struct JumperNote: View {
    let part: Component

    var body: some View {
        if let jumper = part.jumper {
            let unused = part.pads.map(\.name).filter { $0 != jumper.a.name && $0 != jumper.b.name }
            Callout(color: .cyan) {
                Label("Bridge pads \(jumper.a.name) and \(jumper.b.name)", systemImage: "link")
                    .font(.headline)
                Text("Solder the link across the two pads outlined in blue."
                     + (unused.isEmpty ? "" : " Leave pad \(unused.joined(separator: ", ")) empty."))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Says which way round the part goes and how to tell on the physical part.
private struct PolarityNote: View {
    let part: Component

    var body: some View {
        if let polarity = part.polarity {
            Callout(color: .red) {
                Label(polarity.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text(polarity.detail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if part.isReversible {
            Label(part.reversibleNote, systemImage: "arrow.left.arrow.right")
                .foregroundStyle(.green)
        }
    }
}

/// What each pad connects to, for checking a joint with a multimeter.
private struct NetList: View {
    let part: Component

    var body: some View {
        let nets = part.nets
        if !nets.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Connections")
                    .font(.subheadline.weight(.semibold))
                if nets.count <= 8 {
                    ForEach(nets, id: \.pad) { entry in
                        row(entry.pad, entry.net)
                    }
                } else if let mark = part.polarity, let entry = nets.first(where: { $0.pad == mark.padName }) {
                    row(entry.pad, entry.net)
                    Text("\(nets.count - 1) more pins")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ pad: String, _ net: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(pad)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .frame(minWidth: 22, alignment: .trailing)
            Text(net)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }
}

private struct MarkingNote: View {
    @EnvironmentObject private var model: AppModel
    let part: Component

    var body: some View {
        let hint = Marking.hint(for: part)
        let hasDatasheet = part.datasheet?.hasPrefix("http") == true
        let canSearch = !["R", "RN", "C", "L", "FB"].contains(part.prefix)
        if hint != nil || hasDatasheet {
            VStack(alignment: .leading, spacing: 4) {
                if let hint {
                    Label(hint, systemImage: "character.textbox")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if hasDatasheet {
                        Button("Datasheet") { model.openDatasheet(part) }
                    }
                    if canSearch {
                        Button("Look Up Marking") { model.searchMarking(part) }
                            .help("Searches the web for this part's top marking code")
                    }
                }
            }
        }
    }
}

private struct NoteEditor: View {
    @EnvironmentObject private var model: AppModel
    let ref: String

    var body: some View {
        let note = model.note(for: ref)
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                ForEach(PartNote.Flag.allCases, id: \.self) { flag in
                    Button(flag.title, systemImage: flag.symbol) {
                        var changed = note
                        changed.flag = flag
                        model.setNote(changed, for: ref)
                    }
                }
            } label: {
                Label(note.flag == .none ? "Flag a Problem" : note.flag.title, systemImage: note.flag.symbol)
            }
            .fixedSize()
            TextField("Note for \(ref)", text: Binding(
                get: { model.note(for: ref).text },
                set: { text in
                    var changed = model.note(for: ref)
                    changed.text = text
                    model.setNote(changed, for: ref)
                }))
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct ControlBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let total = model.plan.steps.count
        let isDone = model.current == nil
        HStack(spacing: 12) {
            Button("Back", systemImage: "chevron.left") { model.back() }
                .disabled(model.currentIndex == 0)
                .help("Go back and un-mark the previous part (← or Page Up)")
            ProgressView(value: Double(model.placed.count), total: Double(max(total, 1)))
            Text("\(model.placed.count) / \(total)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Skip", systemImage: "chevron.right") { model.skip() }
                .disabled(isDone)
                .help("Come back to this part later (→)")
            Button("Placed · Next", systemImage: "checkmark") { model.markPlaced() }
                .buttonStyle(.borderedProminent)
                .disabled(isDone)
                .help("Mark this part as soldered and show the next one (Space, Return or Page Down)")
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: Kit

/// A checklist of every distinct part to pull from stock before soldering starts.
private struct KitView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let rows = model.kitRows
        let boards = model.state.unitCount
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Take These Parts")
                        .font(.largeTitle.bold())
                    Spacer()
                    Button("Start Assembling", systemImage: "arrow.right") { model.tab = .assemble }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                Text("\(rows.filter { model.state.kitted.contains($0.id) }.count) of \(rows.count) lines pulled · "
                     + "\(rows.reduce(0) { $0 + $1.refs.count }) parts per board"
                     + (boards > 1 ? " · quantities shown for \(boards) boards" : ""))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            List {
                ForEach(Dictionary(grouping: rows, by: \.kind).sorted { $0.key < $1.key }, id: \.key) { kind, lines in
                    Section(kind) {
                        ForEach(lines) { line in
                            row(line, boards: boards)
                        }
                    }
                }
            }
        }
    }

    private func row(_ line: KitRow, boards: Int) -> some View {
        let pulled = model.state.kitted.contains(line.id)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: pulled ? "checkmark.square.fill" : "square")
                .font(.title2)
                .foregroundStyle(pulled ? Color.green : Color.secondary)
            Text("×\(line.refs.count * boards)")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(line.value.isEmpty ? line.footprint : line.value)
                        .font(.title3.weight(.semibold))
                    if let size = line.sizeLabel {
                        Text(size)
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 6)
                            .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                Text(line.refs.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .opacity(pulled ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleKitted(line.id) }
    }
}

// MARK: Order

/// Choose a ready-made order or drag groups into your own.
private struct OrderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Assembly Order")
                    .font(.largeTitle.bold())
                Picker("Start from", selection: Binding(get: { model.state.preset }, set: { model.setPreset($0) })) {
                    ForEach(OrderPreset.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 460)
                HStack {
                    Text(model.state.customOrder == nil
                         ? "Drag any group to move it earlier or later."
                         : "You have rearranged the groups by hand.")
                        .foregroundStyle(.secondary)
                    if model.state.customOrder != nil {
                        Button("Undo My Changes") { model.resetOrder() }
                    }
                }
            }
            .padding(16)
            List {
                ForEach(model.plan.groups) { group in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                        Text("\(group.id + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                        Text(group.value.isEmpty ? group.footprint : group.value)
                            .fontWeight(.semibold)
                        Text(group.sizeLabel ?? group.footprint)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(group.stage.title)
                            .foregroundStyle(.secondary)
                        Text("×\(group.refs.count)")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .onMove { model.moveGroups(from: $0, to: $1) }
            }
        }
    }
}

// MARK: Notes

/// Every part with a flag or note on the current board.
private struct NotesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let refs = model.notedRefs
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes for Board \(model.state.unit + 1)")
                    .font(.largeTitle.bold())
                Text(refs.isEmpty ? "No flags or notes yet. Add them from a part's details while assembling."
                                  : "Click a part to go to it.")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            List(refs, id: \.self) { ref in
                let note = model.note(for: ref)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: note.flag == .none ? "note.text" : note.flag.symbol)
                        .foregroundStyle(.yellow)
                    Text(ref)
                        .fontWeight(.semibold)
                        .frame(width: 60, alignment: .leading)
                    Text(model.component(ref)?.value ?? "")
                        .frame(width: 160, alignment: .leading)
                        .lineLimit(1)
                    if note.flag != .none {
                        Text(note.flag.title)
                    }
                    Text(note.text)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { model.jump(toRef: ref) }
            }
        }
    }
}

// MARK: Bench display

/// A clean, large-type view of the current step for a second screen or an iPad used as one.
struct BenchView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            SceneContainer(controller: model.scene, isPrimary: false)
            if let part = model.current {
                VStack(alignment: .leading, spacing: 6) {
                    Text(part.ref)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                    Text(part.value.isEmpty ? part.footprint : part.value)
                        .font(.system(size: 84, weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                    Text([part.sizeLabel, part.kindName, part.isBottom ? "Bottom side" : "Top side"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    if let jumper = part.jumper {
                        Text("Bridge pads \(jumper.a.name) and \(jumper.b.name)")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.cyan)
                    }
                    if let polarity = part.polarity {
                        Text(polarity.title)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.red)
                    }
                    if let group = model.currentGroup {
                        Text("Take ×\(group.refs.count)")
                            .font(.system(size: 30, weight: .bold))
                    }
                    Text("\(model.placed.count) / \(model.plan.steps.count)")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(20)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}
