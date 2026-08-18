import Foundation

/// The parsed `keymap.conf`. A built-in override is the single chord the menu carries; a custom command's
/// `shortcut` may be empty (palette-only) or hold `|`-separated alternatives, each a chord or a leader
/// sequence. `normalModeBinds` is a second, disjoint namespace, live only while normal mode is on.
public struct Keymap: Equatable, Sendable {
    public let builtinOverrides: [BuiltinAction: Chord]
    public let commands: [CustomCommand]
    /// The built-in binds an `NSMenuItem` cannot carry — a leader sequence, or a second chord where a menu
    /// item holds exactly one key equivalent — dispatched by the app's key monitor instead.
    public let builtinSequences: [BuiltinAction: [Keybind]]
    /// Actions whose `map` line offered no menu-bindable alternative. Distinct from ABSENT, which means
    /// "keep the shipped default": without this, `map ctrl+space>s toggle_split` would leave ⌘D live.
    public let builtinUnbound: Set<BuiltinAction>
    /// The `nmap` binds in file order. They share no namespace with the three above, so nothing here is
    /// reflected in `equivalent(for:)`, `sequences(for:)` or `glyphHint(for:)`.
    public let normalModeBinds: [NormalModeBind]

    public init(builtinOverrides: [BuiltinAction: Chord], normalModeBinds: [NormalModeBind] = [],
                commands: [CustomCommand], builtinSequences: [BuiltinAction: [Keybind]] = [:],
                builtinUnbound: Set<BuiltinAction> = []) {
        self.builtinOverrides = builtinOverrides
        self.normalModeBinds = normalModeBinds
        self.commands = commands
        self.builtinSequences = builtinSequences
        self.builtinUnbound = builtinUnbound
    }

    /// The active menu chord for a built-in: the user override, else the shipped `defaultChord` — `nil` for
    /// the keyless actions and for one a `map` line left explicitly unbound.
    public func equivalent(for action: BuiltinAction) -> Chord? {
        if let override = builtinOverrides[action] { return override }
        return builtinUnbound.contains(action) ? nil : action.defaultChord
    }

    /// The monitor-bound binds for a built-in, empty when it has none.
    public func sequences(for action: BuiltinAction) -> [Keybind] {
        builtinSequences[action] ?? []
    }

    /// The action's whole binding set as macOS menu glyphs, the menu chord first and each monitor-bound
    /// alternative after it, space-separated (`⌘T ⌃␣>S`); `nil` means "not configured", the caller showing no
    /// shortcut. Drives palette hints and toolbar tooltips alike.
    public func glyphHint(for action: BuiltinAction) -> String? {
        let parts = (equivalent(for: action).map { [$0.glyphString] } ?? []) + sequences(for: action).map(\.glyphString)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// One `nmap` line: a keybind firing a built-in action or a custom command while normal mode is on. Kept as
/// a struct rather than a tuple so `Keymap` keeps its synthesized `Equatable`.
///
/// Normal mode is its OWN namespace: nothing reaches the terminal or the global monitor while it is on, so a
/// bind here may freely repeat a global `map` chord or a custom command's, and carries no modifier
/// requirement — bare keys are the point.
public struct NormalModeBind: Equatable, Sendable {
    /// The optional last word of an `nmap` line, overriding the action's own `leavesNormalMode` in either
    /// direction. `insert` is named after the bare exit key and behaves like it: it leaves quietly and sends
    /// no Escape to the pane, which is what keeps `i` and Esc different.
    public enum Mode: String, Equatable, Sendable {
        case insert
        case normal
    }

    public let keybind: Keybind
    public let target: KeybindTarget
    /// `nil` when the line spelled no word, which is what leaves the action in charge.
    public let mode: Mode?

    public init(keybind: Keybind, target: KeybindTarget, mode: Mode? = nil) {
        self.keybind = keybind
        self.target = target
        self.mode = mode
    }

    /// Whether firing this bind also leaves the mode: the line's word when it spelled one, else the built-in
    /// action's own default. A command target has no hand-over default of its own, so it stays in the mode.
    /// The single answer to that question — read by the state machine and by `keymap list` alike.
    public var leavesNormalMode: Bool {
        if let mode { return mode == .insert }
        guard case .builtin(let action) = target else { return false }
        return action.leavesNormalMode
    }
}

/// The bare key that leaves normal mode, vim's `i`. Reserved: `parseKeymap` rejects it as an `nmap` leading
/// chord, and the mode's state machine must honor the same spelling. Esc leaves too but needs no rule here,
/// since `parseKeybind` cannot spell it.
public let normalModeExitKey = "i"

/// A problem found while parsing `keymap.conf`. `line` is 1-based; `0` is a whole-file or cross-section
/// diagnostic belonging to no single line.
public struct KeymapDiagnostic: Equatable, Sendable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

/// Host-free loader for the user keymap file. Missing files recover as an empty keymap with no
/// diagnostics; existing unreadable or invalid-UTF8 files recover with a single line-0 diagnostic.
public struct KeymapStore: Sendable {
    public let configDirectory: URL

    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    public var path: URL {
        ConfigPaths.keymapPath(configDirectory: configDirectory)
    }

    public func load() -> (keymap: Keymap, diagnostics: [KeymapDiagnostic]) {
        do {
            let text = try String(contentsOf: path, encoding: .utf8)
            return parseKeymap(text)
        } catch {
            let empty = Keymap(builtinOverrides: [:], commands: [])
            guard FileManager.default.fileExists(atPath: path.path) else {
                return (empty, [])
            }
            let diagnostic = KeymapDiagnostic(
                line: 0,
                message: "could not read keymap.conf: \(error.localizedDescription)")
            return (empty, [diagnostic])
        }
    }
}

/// Parse the text of a `keymap.conf` into a `Keymap` plus diagnostics. Never throws: a bad line becomes a
/// diagnostic and is skipped, so one malformed line never discards the rest of the file.
///
/// Line-based and kitty-flavored. Blank and `#`-comment lines are ignored (`stripComment` owns the inline
/// rule); the first whitespace token is the verb, `map`, `nmap` or `command`, each owning its own grammar in
/// `parseMapLine` / `parseNormalModeLine` / `parseCommandLine`. Anything else is skipped with a diagnostic.
///
/// Four passes then run over the whole file: `resolveMapLines` folds the `map` lines last-wins to one per
/// action, `resolveBuiltinOverrides` settles built-in-versus-built-in menu chord collisions, `validateBindings`
/// settles every monitor-bound alternative of both verbs against the resulting chord set, and
/// `unboundAfterRestoringStrandedDefaults` hands its default back to an action that ended up with nothing.
/// Only `validateBindings` is order-independent; the first two are order-sensitive by design and by defect
/// respectively (`docs/backlog/builtin-override-collisions-depend-on-line-order.md`).
///
/// `nmap` runs beside all four in `resolveNormalModeBinds`, never through them: normal mode is its own
/// namespace, so an `nmap` bind neither takes a chord from those passes nor loses one to them.
public func parseKeymap(_ text: String) -> (keymap: Keymap, diagnostics: [KeymapDiagnostic]) {
    // collected in file order, NOT folded into a dict yet, so the final duplicate pass resolves them
    // against the FULLY-resolved chord set and can skip the later-in-file member of a colliding pair.
    var mapLines: [ParsedMapLine] = []
    var normalBinds: [ParsedNormalBind] = []
    var commandLines: [ParsedCommandLine] = []
    var diagnostics: [KeymapDiagnostic] = []

    // normalize line endings: a CRLF leaves a trailing `\r` that .whitespaces won't strip (so
    // `toggle_split\r` reads as an unknown action) and a lone-CR file would collapse into one line.
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (index, rawLine) in rawLines.enumerated() {
        let lineNumber = index + 1
        let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }

        let verb = String(line.prefix(while: { !$0.isWhitespace }))
        let rest = String(line.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)

        switch verb {
        case "map":
            parseMapLine(rest, line: lineNumber, mapLines: &mapLines, diagnostics: &diagnostics)
        case "nmap":
            parseNormalModeLine(rest, line: lineNumber, binds: &normalBinds, diagnostics: &diagnostics)
        case "command":
            parseCommandLine(rest, line: lineNumber, commandLines: &commandLines, diagnostics: &diagnostics)
        default:
            diagnostics.append(KeymapDiagnostic(line: lineNumber, message: "unknown verb '\(verb)'"))
        }
    }

    // a final pass, not incremental: the cross-section validation below needs the same resolved chord set.
    let resolved = resolveMapLines(mapLines)
    // Cmd-Shift-D belonged to Dashboard before horizontal split existed. Any valid old configuration that
    // explicitly used that chord keeps it: vacate the new action's default unless the file maps that action.
    var compatibilityUnbound = resolved.unbound
    let horizontalMapped = resolved.overrides.contains { $0.action == .toggleHorizontalSplit }
        || resolved.alternatives[.toggleHorizontalSplit] != nil
        || resolved.unbound.contains(.toggleHorizontalSplit)
    let oldDashboardChord = Chord(mods: [.command, .shift], key: "d")
    let oldConfigUsesHorizontalChord = resolved.overrides.contains {
        $0.action != .toggleHorizontalSplit && $0.chord == oldDashboardChord
    } || resolved.alternatives.contains { action, entry in
        action != .toggleHorizontalSplit && entry.alternatives.contains { $0.keybind.first == oldDashboardChord }
    } || commandLines.contains { line in
        line.alternatives.contains { $0.keybind.first == oldDashboardChord }
    }
    if !horizontalMapped, oldConfigUsesHorizontalChord {
        compatibilityUnbound.insert(.toggleHorizontalSplit)
    }
    // Cmd-Shift-G was previously free. An existing explicit binding on it keeps working; Dashboard becomes
    // keyless until the user maps it, instead of a new shipped default invalidating their configuration.
    let newDashboardChord = Chord(mods: [.command, .shift], key: "g")
    let dashboardMapped = resolved.overrides.contains { $0.action == .dashboard }
        || resolved.alternatives[.dashboard] != nil || resolved.unbound.contains(.dashboard)
    let oldConfigUsesNewDashboardChord = resolved.overrides.contains {
        $0.action != .dashboard && $0.chord == newDashboardChord
    } || resolved.alternatives.contains { action, entry in
        action != .dashboard && entry.alternatives.contains { $0.keybind.first == newDashboardChord }
    } || commandLines.contains { line in
        line.alternatives.contains { $0.keybind.first == newDashboardChord }
    }
    if !dashboardMapped, oldConfigUsesNewDashboardChord { compatibilityUnbound.insert(.dashboard) }
    let builtinOverrides = resolveBuiltinOverrides(resolved.overrides, unbound: compatibilityUnbound,
                                                   alternatives: resolved.alternatives, diagnostics: &diagnostics)
    // `commandLines` carries every command's final name and id already; only `shortcut` is still unsettled,
    // and an `nmap` target names neither.
    let normalModeBinds = resolveNormalModeBinds(normalBinds, commands: commandLines.map(\.command),
                                                 diagnostics: &diagnostics)

    // likewise final: a custom line parsed before a later keyless-built-in `map` must still be validated
    // against the override that `map` installs.
    let menuChords = Set(BuiltinAction.allCases.compactMap {
        resolvedMenuChord($0, overrides: builtinOverrides, unbound: compatibilityUnbound)
    })
    let survivors = validateBindings(monitorAlternatives(commandLines: commandLines,
                                                         mapAlternatives: resolved.alternatives),
                                     menuChords: menuChords, diagnostics: &diagnostics)

    return (Keymap(builtinOverrides: builtinOverrides, normalModeBinds: normalModeBinds,
                   commands: applySurvivingShortcuts(to: commandLines, survivors: survivors),
                   builtinSequences: survivingAlternatives(survivors),
                   builtinUnbound: unboundAfterRestoringStrandedDefaults(compatibilityUnbound,
                                                                         overrides: builtinOverrides,
                                                                         survivors: survivors)),
            diagnostics)
}

/// Whether a diagnostic is about a binding as a whole or about one alternative of several. The ONLY thing
/// separating the two wordings, so a single-alternative binding's text stays byte-identical to the
/// pre-alternatives one; each verb spells its own whole-binding half.
private enum DropScope {
    case wholeBinding
    case alternative

    init(hasSiblings: Bool) {
        self = hasSiblings ? .alternative : .wholeBinding
    }

    /// A parse-time or menu-collision rejection on a `map` line.
    var mapSkipped: String {
        self == .wholeBinding ? "map skipped" : "alternative skipped"
    }

    /// A cross-section drop, on either verb.
    var dropped: String {
        self == .wholeBinding ? "keybind dropped" : "alternative dropped"
    }

    /// A `command` line rejection, whose whole-binding half leaves the command in the palette unkeyed.
    var commandSkipped: String {
        self == .wholeBinding ? "treating the line as palette-only" : "alternative skipped"
    }
}

/// The menu chord an action resolves to against a given override set — the parse-time spelling of
/// `Keymap.equivalent(for:)`, shared by the built-in collision fixpoint and the cross-section chord set.
private func resolvedMenuChord(_ action: BuiltinAction, overrides: [BuiltinAction: Chord],
                               unbound: Set<BuiltinAction>) -> Chord? {
    if let chord = overrides[action] { return chord }
    return unbound.contains(action) ? nil : action.defaultChord
}

/// A binding token's alternatives as raw-substring / parsed-keybind pairs — the shape the whole parse carries
/// so a diagnostic and `CustomCommand.shortcut` can quote the user's own spelling instead of a re-render.
private typealias Alternatives = [(raw: String, keybind: Keybind)]

/// A single valid `map` line: the menu-bindable alternative if it has one, plus the monitor-bound rest.
private struct ParsedMapLine {
    let action: BuiltinAction
    let chord: Chord?
    let alternatives: Alternatives
    let line: Int
}

/// One `map` line's monitor-bound alternatives held until the cross-section pass, with the line to report a
/// drop on and the wording scope — the two things the diagnostics need beyond the binds themselves.
private struct MapLineAlternatives {
    let line: Int
    let scope: DropScope
    let alternatives: Alternatives
}

/// A `command` line's monitor-bound alternatives held beside the command they key, so nothing re-parses
/// `CustomCommand.shortcut` and `applySurvivingShortcuts` is the one place its string form is produced.
private struct ParsedCommandLine {
    let command: CustomCommand
    let alternatives: Alternatives
}

/// A menu-bound `map` alternative, retained in file order until the final cross-builtin duplicate pass.
private struct ParsedOverride {
    let action: BuiltinAction
    let chord: Chord
    let line: Int
}

/// A single valid `nmap` line, retained in file order so a prefix conflict can drop the later one.
/// Internal rather than private, unlike its `map` siblings, so `NormalModeStateTests` can drive resolution
/// without going through a whole keymap file.
struct ParsedNormalBind {
    let keybind: Keybind
    let target: PendingNormalTarget
    let line: Int
    /// The mode word the line spelled, `nil` when it said nothing.
    var mode: NormalModeBind.Mode?
}

/// An `nmap` target before the cross-section pass. A built-in name resolves on its own line; a quoted command
/// name cannot, because the `command` line declaring it may sit further down the file.
enum PendingNormalTarget: Equatable {
    case builtin(BuiltinAction)
    case commandName(String)
}

/// Fold the file-order `map` lines to one per action and split them by dispatch path. A `map` line declares
/// an action's WHOLE binding set, so a later line replaces the earlier one's menu chord and alternatives
/// together — including replacing a menu chord with nothing, which is what `unbound` records.
private func resolveMapLines(_ mapLines: [ParsedMapLine])
    -> (overrides: [ParsedOverride], alternatives: [BuiltinAction: MapLineAlternatives],
        unbound: Set<BuiltinAction>) {
    var latest: [BuiltinAction: ParsedMapLine] = [:]
    for mapLine in mapLines { latest[mapLine.action] = mapLine }

    var overrides: [ParsedOverride] = []
    var alternatives: [BuiltinAction: MapLineAlternatives] = [:]
    var unbound: Set<BuiltinAction> = []
    for mapLine in latest.values.sorted(by: { $0.line < $1.line }) {
        if let chord = mapLine.chord {
            overrides.append(ParsedOverride(action: mapLine.action, chord: chord, line: mapLine.line))
        } else {
            unbound.insert(mapLine.action)
        }
        guard !mapLine.alternatives.isEmpty else { continue }
        let scope = DropScope(hasSiblings: mapLine.chord != nil || mapLine.alternatives.count > 1)
        alternatives[mapLine.action] = MapLineAlternatives(line: mapLine.line, scope: scope,
                                                           alternatives: mapLine.alternatives)
    }
    return (overrides, alternatives, unbound)
}

/// Fold the file-order overrides into the final `[BuiltinAction: Chord]`, rejecting only a TRUE
/// final-state collision: two DISTINCT actions resolving to the same chord. Order-independent — NOT
/// decided against a partially-built map — so moving a built-in off a chord and another claiming it
/// succeed in EITHER line order. Re-mapping the SAME action is last-wins and can't collide with itself.
///
/// Fold last-wins per action, then iterate to a FIXPOINT, since a dropped loser REVERTS to its own default
/// and may collide afresh. An override colliding with another action's UNMOVED default loses; two
/// colliding OVERRIDES drop the later-in-file one; each drop is diagnosed. The shipped defaults are all
/// distinct (pinned by `BuiltinActionTests`), so every collision involves ≥1 override and each iteration
/// removes one — the loop terminates.
///
/// `unbound` is the set of actions a `map` line left with no menu chord at all; they occupy nothing, so
/// another built-in may claim the default they no longer use. `alternatives` names the lines that also carry
/// monitor-bound binds, which this pass never touches — only a line offering nothing else is skipped whole.
private func resolveBuiltinOverrides(_ overrides: [ParsedOverride], unbound: Set<BuiltinAction>,
                                     alternatives: [BuiltinAction: MapLineAlternatives],
                                     diagnostics: inout [KeymapDiagnostic]) -> [BuiltinAction: Chord] {
    // fold last-wins, remembering each winner's file line so a two-override collision can name the later.
    var candidates: [BuiltinAction: Chord] = [:]
    var overrideLine: [BuiltinAction: Int] = [:]
    for override in overrides {
        candidates[override.action] = override.chord
        overrideLine[override.action] = override.line
    }

    // one loser per pass. drops are line-sorted at the end so diagnostics don't depend on dictionary order.
    var pending: [(loser: BuiltinAction, keeper: BuiltinAction, line: Int)] = []
    while let drop = firstBuiltinCollision(candidates: candidates, unbound: unbound, overrideLine: overrideLine) {
        candidates.removeValue(forKey: drop.loser)
        pending.append(drop)
    }

    for drop in pending.sorted(by: { $0.line < $1.line }) {
        let scope = DropScope(hasSiblings: alternatives[drop.loser] != nil)
        diagnostics.append(KeymapDiagnostic(
            line: drop.line,
            message: "chord conflicts with built-in '\(drop.keeper.rawValue)'; \(scope.mapSkipped)"))
    }

    return candidates
}

/// One fixpoint iteration: the first chord two distinct actions resolve to, returned as the loser to drop,
/// the keeper, and the loser's file line. nil when the candidate set is collision-free.
private func firstBuiltinCollision(candidates: [BuiltinAction: Chord], unbound: Set<BuiltinAction>,
                                   overrideLine: [BuiltinAction: Int])
    -> (loser: BuiltinAction, keeper: BuiltinAction, line: Int)? {
    // an unbound action holds no chord, so its shipped default stops blocking another built-in. It has no
    // candidate to drop either, which keeps the loop terminating.
    var ownersByChord: [Chord: [BuiltinAction]] = [:]
    for action in BuiltinAction.allCases {
        guard let chord = resolvedMenuChord(action, overrides: candidates, unbound: unbound) else { continue }
        ownersByChord[chord, default: []].append(action)
    }

    // pick the colliding chord deterministically by its earliest-line loser so the loop is stable.
    var best: (loser: BuiltinAction, keeper: BuiltinAction, line: Int)?
    for owners in ownersByChord.values where owners.count > 1 {
        let overriddenOwners = owners.filter { candidates[$0] != nil }
        let defaultOwners = owners.filter { candidates[$0] == nil }
        let decision: (loser: BuiltinAction, keeper: BuiltinAction)?
        if let defaultOwner = defaultOwners.first, let loser = overriddenOwners.first {
            decision = (loser, defaultOwner)
        } else if overriddenOwners.count > 1 {
            let sorted = overriddenOwners.sorted { (overrideLine[$0] ?? 0) < (overrideLine[$1] ?? 0) }
            decision = (sorted[sorted.count - 1], sorted[0])
        } else {
            decision = nil
        }
        guard let decision else { continue }
        let line = overrideLine[decision.loser] ?? 0
        if best == nil || line < best!.line {
            best = (decision.loser, decision.keeper, line)
        }
    }
    return best
}

/// One monitor-bound alternative entering the cross-section passes: its owner, the raw spelling to quote back,
/// the parsed keybind the passes compare, and the line to report a drop on — `0` for a custom command, whose
/// source line is not tracked.
private struct MonitorAlternative {
    let target: KeybindTarget
    let ownerName: String
    let raw: String
    let keybind: Keybind
    let scope: DropScope
    let line: Int

    var owner: String {
        switch target {
        case .command: return "custom command '\(ownerName)'"
        case .builtin: return "built-in '\(ownerName)'"
        }
    }

    var subject: String {
        switch target {
        case .command: return "\(owner) shortcut '\(raw)'"
        case .builtin: return "\(owner) chord '\(raw)'"
        }
    }
}

/// Every monitor-bound alternative of both verbs, custom commands first and `map` lines in file order — the
/// records the cross-section passes compare, drop and quote back.
private func monitorAlternatives(commandLines: [ParsedCommandLine],
                                 mapAlternatives: [BuiltinAction: MapLineAlternatives]) -> [MonitorAlternative] {
    var alternatives: [MonitorAlternative] = []
    for commandLine in commandLines {
        let scope = DropScope(hasSiblings: commandLine.alternatives.count > 1)
        alternatives += commandLine.alternatives.map {
            MonitorAlternative(target: .command(commandLine.command.id), ownerName: commandLine.command.name,
                               raw: $0.raw, keybind: $0.keybind, scope: scope, line: 0)
        }
    }
    for (action, entry) in mapAlternatives.sorted(by: { $0.value.line < $1.value.line }) {
        alternatives += entry.alternatives.map {
            MonitorAlternative(target: .builtin(action), ownerName: action.rawValue, raw: $0.raw,
                               keybind: $0.keybind, scope: entry.scope, line: entry.line)
        }
    }
    return alternatives
}

/// Cross-section validation over every monitor-bound alternative of both verbs, returning the survivors. Only
/// the offending alternative ever goes — its siblings keep firing, which is the whole point of offering
/// alternatives — and a custom command that loses every one of them stays, palette-only.
private func validateBindings(_ alternatives: [MonitorAlternative], menuChords: Set<Chord>,
                              diagnostics: inout [KeymapDiagnostic]) -> [MonitorAlternative] {
    let unshadowed = dropShadowedAlternatives(alternatives, menuChords: menuChords, diagnostics: &diagnostics)
    return dropConflictingAlternatives(unshadowed, diagnostics: &diagnostics)
}

/// Drop every alternative the app would never let the monitor see: one whose FIRST chord is an active built-in
/// menu chord, or that holds a reserved monitor chord at ANY position — the monitor consumes its chord wherever
/// it lands in a leader, so `ctrl+a>ctrl+1` is just as dead as a leading one.
///
/// Built-in menu chords are single, so any bind STARTING with one, single or leader, is shadowed by the menu.
/// Built-in alternatives face the same two tests as custom ones: `map cmd+t|cmd+t>s toggle_split` would
/// otherwise arm the monitor on the very chord that line puts on the menu. `menuChords` already has every
/// override applied, so a bind may freely reuse a default chord the user moved a built-in off of.
private func dropShadowedAlternatives(_ alternatives: [MonitorAlternative], menuChords: Set<Chord>,
                                      diagnostics: inout [KeymapDiagnostic]) -> [MonitorAlternative] {
    var kept: [MonitorAlternative] = []
    for alternative in alternatives {
        let conflictKind: String?
        if let first = alternative.keybind.first, menuChords.contains(first) {
            conflictKind = "a built-in"
        } else if alternative.keybind.contains(where: isReservedMonitorChord) {
            conflictKind = "a reserved shortcut"
        } else {
            conflictKind = nil
        }
        guard let kind = conflictKind else {
            kept.append(alternative)
            continue
        }
        diagnostics.append(KeymapDiagnostic(
            line: alternative.line,
            message: "\(alternative.subject) conflicts with \(kind); \(alternative.scope.dropped)"))
    }
    return kept
}

/// Settle every duplicate-or-prefix conflict among the alternatives pass 1 left, in ONE pass over a relation
/// computed once. A CROSS-TARGET pair drops both sides, upstream's rule for single binds. A SAME-TARGET prefix
/// pair drops the longer alternative, since `KeybindMatcher` fires the exact shorter match and the longer could
/// never run; both spell the same thing, so nothing is lost.
///
/// Nothing is recomputed and no drop cascades, which is what makes the outcome independent of the order the
/// file writes its lines and its `|` alternatives in. The price is that an alternative whose only conflict was
/// with one that also went still dies; that is the deliberate cost of determinism, not an omission — do not
/// add a recovery pass for it.
///
/// A cross-target diagnostic names the OTHER offender so the user can find the pair; a same-target one names
/// the owner both alternatives share. A target's alternatives are deduped, so target plus keybind locates
/// exactly one of them.
private func dropConflictingAlternatives(_ alternatives: [MonitorAlternative],
                                         diagnostics: inout [KeymapDiagnostic]) -> [MonitorAlternative] {
    var position: [KeybindConflict.Side: Int] = [:]
    for (index, alternative) in alternatives.enumerated() {
        position[KeybindConflict.Side(target: alternative.target, keybind: alternative.keybind)] = index
    }
    var otherOffender: [Int: String] = [:]
    func charge(_ index: Int, with offender: String) {
        if otherOffender[index] == nil { otherOffender[index] = offender }
    }
    for conflict in keybindConflicts(alternatives.map { (keybind: $0.keybind, target: $0.target) }) {
        guard let first = position[conflict.first], let second = position[conflict.second] else { continue }
        guard conflict.first.target != conflict.second.target else {
            let longer = isStrictKeybindPrefix(conflict.first.keybind, of: conflict.second.keybind) ? second : first
            charge(longer, with: alternatives[longer].owner)
            continue
        }
        charge(first, with: alternatives[second].owner)
        charge(second, with: alternatives[first].owner)
    }

    var survivors: [MonitorAlternative] = []
    for (index, alternative) in alternatives.enumerated() {
        guard let other = otherOffender[index] else {
            survivors.append(alternative)
            continue
        }
        diagnostics.append(KeymapDiagnostic(
            line: alternative.line,
            message: "\(alternative.subject) conflicts with \(other); \(alternative.scope.dropped)"))
    }
    return survivors
}

/// The surviving monitor-bound binds per built-in, in file order.
private func survivingAlternatives(_ survivors: [MonitorAlternative]) -> [BuiltinAction: [Keybind]] {
    var alternatives: [BuiltinAction: [Keybind]] = [:]
    for survivor in survivors {
        guard case .builtin(let action) = survivor.target else { continue }
        alternatives[action, default: []].append(survivor.keybind)
    }
    return alternatives
}

/// The parsed commands with each keyed one's `shortcut` written from the raw substrings its alternatives kept
/// — the single place the string form is produced, splicing rather than re-rendering so the user's own
/// spelling survives. A command that lost every alternative ends up with `shortcut == ""`, palette-only.
private func applySurvivingShortcuts(to commandLines: [ParsedCommandLine],
                                     survivors: [MonitorAlternative]) -> [CustomCommand] {
    var raws: [UUID: [String]] = [:]
    for survivor in survivors {
        guard case .command(let id) = survivor.target else { continue }
        raws[id, default: []].append(survivor.raw)
    }
    return commandLines.map { commandLine in
        guard !commandLine.alternatives.isEmpty else { return commandLine.command }
        var command = commandLine.command
        command.shortcut = (raws[command.id] ?? []).joined(separator: "|")
        return command
    }
}

/// The unbound set with every STRANDED action removed — one whose `map` line lost its last bind in the
/// cross-section passes, which goes back to its shipped default exactly as one rejected while parsing does:
/// the line bound nothing, so leaving the action keyless would take away a chord the file never asked to move.
/// An action stays unbound when something else already holds that chord, which being unbound is what
/// permitted — the passes above ran against a chord set this action had vacated.
private func unboundAfterRestoringStrandedDefaults(_ unbound: Set<BuiltinAction>,
                                                   overrides: [BuiltinAction: Chord],
                                                   survivors: [MonitorAlternative]) -> Set<BuiltinAction> {
    let stillBound = Set(survivors.compactMap { survivor -> BuiltinAction? in
        guard case .builtin(let action) = survivor.target else { return nil }
        return action
    })
    let stranded = unbound.subtracting(stillBound)
    guard !stranded.isEmpty else { return unbound }

    var occupied = Set(survivors.compactMap(\.keybind.first))
    for action in BuiltinAction.allCases where !stranded.contains(action) {
        guard let chord = resolvedMenuChord(action, overrides: overrides, unbound: unbound) else { continue }
        occupied.insert(chord)
    }
    // the shipped defaults are all distinct, so two stranded actions can never want the same chord.
    return unbound.subtracting(stranded.filter { action in
        guard let chord = action.defaultChord else { return false }
        return !occupied.contains(chord)
    })
}

/// Strip a trailing inline comment: a `#` counts only when preceded by whitespace AND outside a quoted
/// span, single OR double. A whole-line `#` comment falls out here too, leaving an empty line for the
/// caller. Single quotes matter so a shell line like `git commit -m 'fix #42'` keeps its `#`; the two
/// quote states are mutually exclusive (a `"` inside `'...'` is literal, and vice versa).
private func stripComment(_ line: String) -> String {
    var inSingleQuotes = false
    var inDoubleQuotes = false
    var previousWasSpace = true // start-of-line counts as preceded-by-whitespace, so a leading `#` cuts
    var result = ""
    for ch in line {
        if ch == "\"" && !inSingleQuotes {
            inDoubleQuotes.toggle()
            result.append(ch)
            previousWasSpace = false
            continue
        }
        if ch == "'" && !inDoubleQuotes {
            inSingleQuotes.toggle()
            result.append(ch)
            previousWasSpace = false
            continue
        }
        if ch == "#" && !inSingleQuotes && !inDoubleQuotes && previousWasSpace {
            break
        }
        result.append(ch)
        previousWasSpace = ch.isWhitespace
    }
    return result
}

/// Parse a `map` line's remainder, `<chord> <action>`: on success appends a `ParsedMapLine` in file order,
/// on any failure a diagnostic, leaving `mapLines` untouched. Cross-builtin duplicate detection is deferred
/// to `resolveBuiltinOverrides`.
private func parseMapLine(_ rest: String, line: Int, mapLines: inout [ParsedMapLine],
                          diagnostics: inout [KeymapDiagnostic]) {
    // split on the first run of general whitespace (space OR tab) so a tab-separated `map` line works.
    let chordText = String(rest.prefix(while: { !$0.isWhitespace }))
    let actionName = String(rest.dropFirst(chordText.count)).trimmingCharacters(in: .whitespaces)
    guard !chordText.isEmpty, !actionName.isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "map requires a chord and an action"))
        return
    }

    guard let parsed = alternativeKeybinds(chordText) else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "invalid chord '\(chordText)'"))
        return
    }

    let split = splitMapAlternatives(parsed, line: line, diagnostics: &diagnostics)
    // nothing survived: report no action diagnostic on top of the per-alternative ones, as before.
    guard split.chord != nil || !split.alternatives.isEmpty else { return }
    guard let action = BuiltinAction(rawValue: actionName) else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "unknown action '\(actionName)'"))
        return
    }
    mapLines.append(ParsedMapLine(action: action, chord: split.chord, alternatives: split.alternatives,
                                  line: line))
}

/// Sort a `map` line's alternatives by dispatch path: the first one that can be a menu key equivalent — a
/// single chord passing `map`'s own rules — becomes it, every other one is monitor-bound and follows the
/// monitor's rule instead. The grammar tracks the DISPATCH PATH, not the verb.
///
/// An alternative breaking its path's rule is diagnosed and dropped alone, leaving its siblings; the caller
/// treats a line that kept nothing as having bound nothing. (A MALFORMED alternative never reaches here —
/// `alternativeKeybinds` already killed the line, so a typo cannot hide behind a line that half worked.)
private func splitMapAlternatives(_ parsed: Alternatives, line: Int,
                                  diagnostics: inout [KeymapDiagnostic]) -> (chord: Chord?,
                                                                             alternatives: Alternatives) {
    let scope = DropScope(hasSiblings: parsed.count > 1)
    var menuChord: Chord?
    var alternatives: Alternatives = []
    for alternative in parsed {
        // a chord owned by an always-on NSEvent monitor can't be a menu key-equivalent without dead-racing
        // the monitor, and is just as dead deeper in a sequence, so reject it at any position.
        guard !alternative.keybind.contains(where: isReservedMonitorChord) else {
            diagnostics.append(KeymapDiagnostic(
                line: line,
                message: "chord '\(alternative.raw)' is a reserved shortcut; \(scope.mapSkipped)"))
            continue
        }
        if menuChord == nil, alternative.keybind.count == 1, let chord = alternative.keybind.first {
            // a modifier-less arrow would install an always-on menu key-equivalent swallowing the key
            // everywhere — terminal, palettes, dashboard grid, every text field — and the menu path, unlike
            // the custom-command monitor, has no text-field pass-through.
            guard !(bindableArrowKeys.contains(chord.key) && chord.mods.isEmpty) else {
                diagnostics.append(KeymapDiagnostic(
                    line: line,
                    message: "bare arrow chord '\(alternative.raw)' needs a modifier; \(scope.mapSkipped)"))
                continue
            }
            menuChord = chord
            continue
        }
        // monitor-bound: a bare first chord would be swallowed everywhere in the terminal, the rule
        // `parseCommandLine` already applies to every custom shortcut.
        guard alternative.keybind.first?.mods.isEmpty == false else {
            diagnostics.append(KeymapDiagnostic(
                line: line,
                message: "chord '\(alternative.raw)' needs a modifier on its first key; \(scope.mapSkipped)"))
            continue
        }
        alternatives.append(alternative)
    }
    return (menuChord, alternatives)
}

/// Parse an `nmap` line's remainder, `<chord-or-sequence> <action|"<command name>"> [insert|normal]`: on
/// success appends a `ParsedNormalBind` in file order, on any failure a diagnostic. The trailing word is the
/// one grammar piece `map` does not take: a global chord fires outside the mode, where there is no mode to
/// leave.
///
/// Deliberately NO modifier rule, the one grammar difference from `map`: normal mode intercepts every key
/// before the terminal sees it, so a bare `j` swallows nothing the user still wants. Reserved monitor chords
/// and Command chords stay rejected at any position — the monitor never lets the MODE take either, so a bind
/// on one could not fire and the chord would run whatever `map` or the menu bar already owns — and
/// `normalModeExitKey` is rejected as a leading chord because it is how the user gets back out. Those chord
/// rules are applied before the target is read, so they hold for a command target exactly as they do for a
/// built-in one.
///
/// One bind per line, through `parseKeybind` rather than `alternativeKeybinds`: `|` alternatives exist so a
/// binding can offer a menu chord AND a monitor one, and normal mode has only the second path.
private func parseNormalModeLine(_ rest: String, line: Int, binds: inout [ParsedNormalBind],
                                 diagnostics: inout [KeymapDiagnostic]) {
    let chordText = String(rest.prefix(while: { !$0.isWhitespace }))
    let targetText = String(rest.dropFirst(chordText.count)).trimmingCharacters(in: .whitespaces)
    guard !chordText.isEmpty, !targetText.isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "nmap requires a key and an action"))
        return
    }

    guard let keybind = parseKeybind(chordText), let firstChord = keybind.first else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "invalid chord '\(chordText)'"))
        return
    }
    guard !keybind.contains(where: isReservedMonitorChord) else {
        diagnostics.append(KeymapDiagnostic(line: line,
                                            message: "chord '\(chordText)' is a reserved shortcut; nmap skipped"))
        return
    }
    guard !keybind.contains(where: { $0.mods.contains(.command) }) else {
        diagnostics.append(KeymapDiagnostic(
            line: line,
            message: "chord '\(chordText)' uses cmd, which normal mode never takes; nmap skipped"))
        return
    }
    // only as a LEADING chord: the exit key is consulted when no leader is armed, so `space>i` is unambiguous.
    guard !(firstChord.mods.isEmpty && firstChord.key == normalModeExitKey) else {
        diagnostics.append(KeymapDiagnostic(
            line: line,
            message: "'\(normalModeExitKey)' leaves normal mode and can't be bound; nmap skipped"))
        return
    }
    guard let split = splitNormalModeWord(targetText, line: line, diagnostics: &diagnostics) else { return }
    guard let target = parseNormalModeTarget(split.target, line: line, diagnostics: &diagnostics) else { return }

    binds.append(ParsedNormalBind(keybind: keybind, target: target, line: line, mode: split.mode))
}

/// Split the optional trailing mode word off an `nmap` target, so both target forms obey ONE rule: the
/// quoted form used to reject trailing text inside `parseNormalModeTarget`, and a bare action name used to
/// swallow it into the name it then failed to resolve.
///
/// Where the target ends is the only per-form difference — the closing quote, else the first whitespace.
/// Anything after it must be a mode word; anything else is a diagnostic naming it, and the line is skipped,
/// the same way a malformed alternative kills its whole line. An unterminated quote is left alone for
/// `parseNormalModeTarget` to report, since nothing in it can be told apart from the name.
///
/// The word must be whitespace-delimited, which only the quoted form can violate: a bare name runs to the
/// first whitespace, so `toggle_scratchinsert` is one unresolvable action, but a closing quote ends the
/// target wherever it sits. Without the check `nmap f "FZF Files"insert` would bind and silently hand the
/// keyboard over, where before the word existed the line was a diagnostic.
private func splitNormalModeWord(_ text: String, line: Int, diagnostics: inout [KeymapDiagnostic])
    -> (target: String, mode: NormalModeBind.Mode?)? {
    let targetEnd: String.Index
    if text.first == "\"" {
        guard let closeQuote = text.dropFirst().firstIndex(of: "\"") else { return (text, nil) }
        targetEnd = text.index(after: closeQuote)
        if targetEnd < text.endIndex, !text[targetEnd].isWhitespace {
            diagnostics.append(KeymapDiagnostic(
                line: line, message: "mode word must be separated from the command name; nmap skipped"))
            return nil
        }
    } else {
        targetEnd = text.firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
    }
    let trailing = text[targetEnd...].trimmingCharacters(in: .whitespaces)
    guard !trailing.isEmpty else { return (String(text[..<targetEnd]), nil) }
    guard let mode = NormalModeBind.Mode(rawValue: trailing) else {
        diagnostics.append(KeymapDiagnostic(
            line: line, message: "unknown mode '\(trailing)'; nmap skipped"))
        return nil
    }
    return (String(text[..<targetEnd]), mode)
}

/// The target half of an `nmap` line. A leading `"` marks a custom-command name, the same way a `command`
/// line spells its own name; anything else is a built-in action name. An unterminated quote is its own
/// diagnostic rather than a fallthrough, since `"Some command` can never be a legal action name either.
private func parseNormalModeTarget(_ text: String, line: Int,
                                   diagnostics: inout [KeymapDiagnostic]) -> PendingNormalTarget? {
    guard text.first == "\"" else {
        guard let action = BuiltinAction(rawValue: text) else {
            diagnostics.append(KeymapDiagnostic(line: line, message: "unknown action '\(text)'"))
            return nil
        }
        return .builtin(action)
    }
    guard let closeQuote = text.dropFirst().firstIndex(of: "\"") else {
        diagnostics.append(KeymapDiagnostic(line: line,
                                            message: "unterminated command name; nmap skipped"))
        return nil
    }
    return .commandName(String(text[text.index(after: text.startIndex)..<closeQuote]))
}

/// How a normal-mode target names itself in a diagnostic. A built-in keeps the quoted action name it always
/// had; a command reads `command "<name>"` so the two can't be confused. An unresolvable id can only come
/// from a bug, so it falls back to the raw id rather than hiding.
private func normalModeTargetName(_ target: KeybindTarget, commands: [CustomCommand]) -> String {
    switch target {
    case .builtin(let action):
        return "'\(action.rawValue)'"
    case .command(let id):
        guard let name = commands.first(where: { $0.id == id })?.name else { return "command \(id.uuidString)" }
        return "command \"\(name)\""
    }
}

/// Resolve every `nmap` line's target against the finished `commands`, then drop any bind in a prefix
/// relation with an earlier one — the wait-or-fire ambiguity, a duplicate being the equal-length case —
/// keeping the earlier line as two colliding built-in sequences do. One pass in file order suffices: a drop
/// frees nothing, so it can't make a surviving bind newly legal.
///
/// Resolution runs here rather than per line so an `nmap` may name a command declared anywhere in the file.
/// A name matching nothing is dropped with a diagnostic on its own line and blocks no later bind.
///
/// Checked against `nmap` binds ONLY. Normal mode is its own namespace, so a bind repeating a global `map`
/// chord or a custom command's shortcut is intentional, not a conflict.
func resolveNormalModeBinds(_ parsed: [ParsedNormalBind], commands: [CustomCommand],
                            diagnostics: inout [KeymapDiagnostic]) -> [NormalModeBind] {
    // `keybindConflicts` computes the same relation for the global namespace, but reports it as pairs over a
    // finished set; here each bind is tested against the ones already kept, so the test is spelled out.
    func conflicts(_ lhs: Keybind, _ rhs: Keybind) -> Bool {
        lhs == rhs || isStrictKeybindPrefix(lhs, of: rhs) || isStrictKeybindPrefix(rhs, of: lhs)
    }

    var kept: [NormalModeBind] = []
    for entry in parsed {
        let target: KeybindTarget
        switch entry.target {
        case .builtin(let action):
            target = .builtin(action)
        case .commandName(let name):
            guard let command = commands.first(where: { $0.name == name }) else {
                diagnostics.append(KeymapDiagnostic(line: entry.line,
                                                    message: "unknown command '\(name)'; nmap skipped"))
                continue
            }
            target = .command(command.id)
        }
        if let clash = kept.first(where: { conflicts($0.keybind, entry.keybind) }) {
            let name = normalModeTargetName(clash.target, commands: commands)
            diagnostics.append(KeymapDiagnostic(
                line: entry.line,
                message: "normal-mode keybind conflicts with \(name); nmap skipped"))
            continue
        }
        kept.append(NormalModeBind(keybind: entry.keybind, target: target, mode: entry.mode))
    }
    return kept
}

/// Parse the remainder of a `command` line (after the verb): `"<name>" [chord] <shell...>`. On any failure
/// it appends a diagnostic and leaves `commandLines` untouched. The kept alternatives ride alongside the
/// command; `applySurvivingShortcuts` is what turns them back into `CustomCommand.shortcut`.
private func parseCommandLine(_ rest: String, line: Int, commandLines: inout [ParsedCommandLine],
                              diagnostics: inout [KeymapDiagnostic]) {
    guard rest.first == "\"", let closeQuote = rest.dropFirst().firstIndex(of: "\"") else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "command requires a quoted name"))
        return
    }
    let name = String(rest[rest.index(after: rest.startIndex)..<closeQuote])
    let afterName = String(rest[rest.index(after: closeQuote)...]).trimmingCharacters(in: .whitespaces)

    // EVERY alternative's first chord must carry a modifier: a bare key would shadow that key in the
    // terminal, and a palette-only shell line starting with a single-char token (`[`, `:`, a one-letter
    // alias) would be swallowed as a binding. One alternative failing that drops alone, as on a `map` line;
    // the token stays shell only when NOTHING in it is bindable, which is what keeps `command "x" a|b echo`
    // running the same shell line it always did.
    let firstToken = String(afterName.prefix(while: { !$0.isWhitespace }))
    var kept: Alternatives = []
    var shellLine = afterName
    if !firstToken.isEmpty, let parsed = alternativeKeybinds(firstToken) {
        kept = parsed.filter { $0.keybind.first?.mods.isEmpty == false }
        if kept.isEmpty {
            diagnostics.append(KeymapDiagnostic(line: line,
                message: "command '\(name)' shortcut '\(firstToken)' must include a modifier; \(DropScope.wholeBinding.commandSkipped)"))
        } else {
            for dropped in parsed where dropped.keybind.first?.mods.isEmpty != false {
                diagnostics.append(KeymapDiagnostic(line: line,
                    message: "command '\(name)' shortcut '\(dropped.raw)' must include a modifier; \(DropScope.alternative.commandSkipped)"))
            }
            shellLine = String(afterName.dropFirst(firstToken.count)).trimmingCharacters(in: .whitespaces)
        }
    } else if hasMalformedAlternative(firstToken) {
        // a token mixing a real alternative with a malformed one is a typo, not a shell line. Saying so is
        // what keeps a malformed alternative from hiding inside the command instead of killing the binding.
        diagnostics.append(KeymapDiagnostic(line: line,
            message: "command '\(name)' shortcut '\(firstToken)' has an invalid alternative; \(DropScope.wholeBinding.commandSkipped)"))
    }

    // an empty shell line (just a name, or a name + chord with no command) is a no-op binding; skip it.
    guard !shellLine.trimmingCharacters(in: .whitespaces).isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "command '\(name)' has no shell line"))
        return
    }

    commandLines.append(ParsedCommandLine(command: CustomCommand(name: name, command: shellLine, shortcut: ""),
                                          alternatives: kept))
}
