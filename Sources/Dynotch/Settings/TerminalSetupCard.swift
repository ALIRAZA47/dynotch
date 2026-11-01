import SwiftUI

/// What the Terminal setup card is doing, around `TerminalSetup`, which does the work.
@MainActor
final class TerminalSetupModel: ObservableObject {
    enum Step: Equatable {
        case resting
        /// The changes are on show, waiting for a click.
        case reviewingInstall, reviewingUndo
    }

    static let shared = TerminalSetupModel()

    @Published private(set) var step = Step.resting
    /// What's ticked in the review.
    @Published var selection = Set<SetupItem>()
    @Published private(set) var states: [SetupItem: TerminalSetup.State] = [:]
    /// How the last click went.
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    /// Why this copy of Dynotch can't set anything up.
    @Published private(set) var problem: String?
    /// Scrolls the card into view, for snapshots.
    @Published var revealRequested = false

    private var setup: TerminalSetup?
    /// What was on show when the review started, so a file changed since then isn't overwritten unseen.
    private var reviewed = ""

    private init() {
        problem = TerminalSetup.problem(with: .main)
        guard problem == nil, let resources = Bundle.main.resourceURL else { return }
        setup = TerminalSetup(home: FileManager.default.homeDirectoryForCurrentUser, resources: resources)
    }

    init(setup: TerminalSetup) {
        self.setup = setup
    }

    var items: [SetupItem] {
        step == .resting ? SetupItem.allCases : SetupItem.allCases.filter { offered($0) }
    }

    var installedCount: Int { states.values.filter { $0 == .installed }.count }
    var canInstall: Bool { SetupItem.allCases.contains { setup?.canInstall($0) == true } }
    var canUndo: Bool { SetupItem.allCases.contains { setup?.canUndo($0) == true } }

    /// Whether an item is part of what the review would do, picked or brought along by another.
    func isIncluded(_ item: SetupItem) -> Bool {
        !changes(for: item).isEmpty
    }

    /// Flips an item in the review, with whatever goes with it, so what's on show is what happens.
    func toggle(_ item: SetupItem) {
        let turningOn = !isIncluded(item)
        let needing = SetupItem.allCases.filter(\.needsCommand)
        if step == .reviewingUndo {
            if turningOn {
                selection.insert(item)
            } else {
                selection.remove(item)
                // The link can't go while something that needs it stays.
                if item.needsCommand { selection.remove(.command) }
            }
        } else if turningOn {
            selection.insert(item)
        } else {
            selection.remove(item)
            if item == .command { selection.subtract(needing) }
        }
    }

    /// The changes on show for an item in the review. What it needs is shown with what it's for.
    func changes(for item: SetupItem) -> [TerminalSetup.Change] {
        guard let setup else { return [] }
        let all = step == .reviewingUndo ? setup.undoChanges(for: selection) : setup.installChanges(for: selection)
        return all.filter { $0.item == item }
    }

    func refresh() {
        guard let setup else { return }
        states = Dictionary(uniqueKeysWithValues: SetupItem.allCases.map { ($0, setup.state(of: $0)) })
    }

    func reviewInstall() {
        refresh()
        message = nil
        selection = Set(SetupItem.allCases.filter { setup?.canInstall($0) == true })
        reviewed = setup?.fingerprint ?? ""
        step = .reviewingInstall
    }

    func reviewUndo() {
        refresh()
        message = nil
        selection = Set(SetupItem.allCases.filter { setup?.canUndo($0) == true })
        reviewed = setup?.fingerprint ?? ""
        step = .reviewingUndo
    }

    func cancel() {
        step = .resting
        refresh()
    }

    func apply() {
        guard let setup else { return }
        do {
            if step == .reviewingUndo {
                try setup.undo(selection, reviewed: reviewed)
                say("Taken out. Everything else in those files stays as it was.")
            } else {
                try setup.install(selection, reviewed: reviewed)
                say("Set up. A new terminal window or Claude Code session picks it up.")
            }
            step = .resting
        } catch TerminalSetup.Failure.changedSinceReview {
            // Back to a fresh look, rather than writing over something nobody has seen.
            let wasUndo = step == .reviewingUndo
            if wasUndo { reviewUndo() } else { reviewInstall() }
            say("A file changed after this was shown, so nothing was touched. Here's how it looks now.", failed: true)
        } catch TerminalSetup.Failure.blocked(let reason) {
            step = .resting
            say(reason, failed: true)
        } catch TerminalSetup.Failure.couldNotWrite(let name) {
            step = .resting
            say("\(name) couldn't be written.", failed: true)
        } catch {
            step = .resting
            say("That didn't work.", failed: true)
        }
        refresh()
    }

    private func say(_ text: String, failed: Bool = false) {
        message = text
        self.failed = failed
    }

    private func offered(_ item: SetupItem) -> Bool {
        step == .reviewingUndo ? setup?.canUndo(item) == true : setup?.canInstall(item) == true
    }

    // MARK: Snapshots

    /// A made-up home and app, so snapshots show nothing of the real files.
    func useSample(home: URL) {
        setup = TerminalSetup(home: home, resources: URL(fileURLWithPath: "/Applications/Dynotch.app/Contents/Resources"))
        problem = nil
        step = .resting
        message = nil
        refresh()
    }

    /// The review as it'd be on show.
    func stageReview(undo: Bool = false) {
        if undo { reviewUndo() } else { reviewInstall() }
    }

    func applyForSample() {
        apply()
    }
}

/// Puts the `dynotch` command, the long-command hook and the Claude Code hooks in place, on the
/// General page. Every change is on show before it's made, and each can be taken out again.
struct TerminalSetupSection: View {
    @ObservedObject private var model = TerminalSetupModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let anchor = "terminal-setup"

    var body: some View {
        ScrollViewReader { proxy in
            SettingsSection(title: "Terminal setup", trailing: model.problem == nil ? "\(model.installedCount) of \(SetupItem.allCases.count) set up" : nil,
                            footer: "This changes ~/.local/bin, ~/.zshrc and ~/.claude/settings.json, only when you say so. Whatever else is in those files stays as it is, and a copy of each goes to Application Support first.") {
                SettingsCard {
                    if let problem = model.problem {
                        Text(problem)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    } else {
                        ForEach(model.items) { item in
                            SetupRow(item: item, model: model)
                            CardDivider()
                        }
                        SetupActions(model: model)
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85), value: model.step)
            }
            .id(Self.anchor)
            .onAppear {
                model.refresh()
                reveal(with: proxy)
            }
            .onChange(of: model.revealRequested) { reveal(with: proxy) }
        }
    }

    private func reveal(with proxy: ScrollViewProxy) {
        guard model.revealRequested else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(Self.anchor, anchor: .top)
            model.revealRequested = false
        }
    }
}

/// One thing that can be set up: how it stands, or in a review, what changes.
private struct SetupRow: View {
    let item: SetupItem
    @ObservedObject var model: TerminalSetupModel

    private var state: TerminalSetup.State { model.states[item] ?? .notInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.step == .resting {
                row.accessibilityElement(children: .combine)
            } else {
                Button { model.toggle(item) } label: { row.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityValue(model.isIncluded(item) ? "On" : "Off")
                    .accessibilityAddTraits(.isToggle)
                ForEach(model.changes(for: item)) { change in
                    ChangeNote(change: change)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var row: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: item.symbol, tint: Palette.lavender, isActive: state == .installed || model.step != .resting, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if model.step == .resting {
                Text(stateText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(state == .installed ? Color.primary : Palette.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                SwitchMark(isOn: model.isIncluded(item))
            }
        }
    }

    private var detail: String {
        if case .blocked(let reason) = state { return reason }
        return item.detail
    }

    private var stateText: String {
        switch state {
        case .installed: "Set up"
        case .notInstalled: "Not set up"
        case .outOfDate: "Needs an update"
        case .blocked: "Left alone"
        }
    }
}

/// What a change does in a line, then exactly what goes in or comes out.
private struct ChangeNote: View {
    let change: TerminalSetup.Change

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(change.summary)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
            Text(change.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.wash))
        }
        .padding(.leading, 38)
    }
}

/// The card's buttons, and how the last click went.
private struct SetupActions: View {
    @ObservedObject var model: TerminalSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.message {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(model.failed ? Color.orange : Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                switch model.step {
                case .resting:
                    if model.canUndo {
                        CapsuleButton(title: "Undo…", kind: .plain) { model.reviewUndo() }
                    }
                    if model.canInstall {
                        CapsuleButton(title: "Review Changes…", kind: .prominent) { model.reviewInstall() }
                    }
                case .reviewingInstall:
                    CapsuleButton(title: "Cancel", kind: .plain) { model.cancel() }
                    CapsuleButton(title: "Install", kind: .prominent) { model.apply() }
                        .disabled(model.selection.isEmpty)
                case .reviewingUndo:
                    CapsuleButton(title: "Cancel", kind: .plain) { model.cancel() }
                    CapsuleButton(title: "Take Out", kind: .destructive) { model.apply() }
                        .disabled(model.selection.isEmpty)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
