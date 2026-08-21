/// The mark agterm writes into a pane at the start of an agent turn, and the token a later `session.search`
/// looks for to jump back to it. Both live here because the jump only works while the written string and the
/// searched string agree, and spelling either at a call site is how the two drift apart.
public enum TurnMark {
    /// `⟦` and `⟧` are effectively never typed, so this cannot match ordinary prose the way a phrase like
    /// `turn 7` does. The closing bracket is what keeps turn 1 from matching turn 10.
    public static func needle(for turn: Int) -> String {
        "⟦\(turn)⟧"
    }

    /// The decoration is cosmetic and may reflow in the pane, which is why it is never the search needle.
    public static func line(for turn: Int) -> String {
        "── \(needle(for: turn)) ──"
    }

    /// The exact bytes to write to the pane's pty. A pty left in raw mode does no `\n` to `\r\n` translation
    /// and the mark would start mid-column; a cooked one folds the extra carriage return away. `\r\n` renders
    /// in both.
    public static func payload(for turn: Int) -> String {
        "\r\n\r\n\(line(for: turn))\r\n"
    }
}
