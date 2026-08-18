/// When a picker that accepts free text offers the query as its own row.
public enum PickCustomRowRule: Sendable {
    /// Only when nothing matched. The control API's `pick --allow-custom`: the caller's items ARE the
    /// answer set, so a surviving match means the caller already listed what the user meant.
    case whenNothingMatched
    /// Whenever no row's title equals the query. For a picker whose free text CREATES something: ranking
    /// is subsequence-based, so `rl` matches `release` and would hide the create row at every query
    /// length, leaving that name impossible to create from the picker at all.
    case whenNoExactTitle
}

/// Returns the synthetic free-text row label, or nil when `rule` says the query is already answered.
/// Whitespace around the query is ignored so an empty search never becomes a selectable value.
/// Callers APPEND the row: under `whenNothingMatched` the list is empty, so appending and replacing agree.
public func pickCustomRowLabel(
    query: String,
    titles: [String],
    allowCustom: Bool,
    verb: String = "Use",
    rule: PickCustomRowRule = .whenNothingMatched
) -> String? {
    let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard allowCustom, !value.isEmpty else { return nil }
    switch rule {
    case .whenNothingMatched:
        guard titles.isEmpty else { return nil }
    case .whenNoExactTitle:
        guard !titles.contains(value) else { return nil }
    }
    return "\(verb) \"\(value)\""
}
