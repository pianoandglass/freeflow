import Foundation

// MARK: - ContextualFormattingService

/// Applies deterministic post-LLM formatting using the surrounding cursor context (AX).
/// When context is nil, each rule falls back to a safe default.
enum ContextualFormattingService {

    // MARK: - Public API

    /// Main entry point. Rules applied in order:
    /// strip trailing whitespace → remove duplicate punctuation → capitalize → compute spacing.
    static func format(
        _ text: String,
        precedingText: String?,
        followingText: String?
    ) -> (text: String, leadingSpace: String, trailingSpace: String) {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return ("", "", "") }

        result = removeDuplicatePunctuation(result, following: followingText)
        result = applyCapitalization(result, preceding: precedingText, following: followingText)

        return (result, leadingSpace(preceding: precedingText), trailingSpace(following: followingText))
    }

    // MARK: - Spacing

    /// No leading space if preceding ends with whitespace or an opening bracket/quote.
    /// Adds a space otherwise (after letters, numbers, or closing punctuation).
    private static func leadingSpace(preceding: String?) -> String {
        guard let preceding, !preceding.isEmpty, let last = preceding.last else { return "" }
        return last.isWhitespace || "([{\"'".contains(last) ? "" : " "
    }

    /// No trailing space if following starts with whitespace, punctuation, or a closing bracket/quote.
    private static func trailingSpace(following: String?) -> String {
        guard let following, !following.isEmpty, let first = following.first else { return "" }
        return first.isWhitespace || ")]},.?!;:'\"".contains(first) ? "" : " "
    }

    // MARK: - Capitalization

    /// Capitalizes after sentence-ending punctuation (.?!…) or at field start.
    /// Lowercases after mid-sentence punctuation (,;:)]}/') or mid-sentence insertion.
    /// Preserves LLM decision when no strong rule applies.
    private static func applyCapitalization(
        _ text: String,
        preceding: String?,
        following: String?
    ) -> String {
        guard let first = text.first, let preceding else { return text }

        let trimmed = preceding.trimmingCharacters(in: .whitespaces)
        let shouldCapitalize: Bool

        if trimmed.isEmpty {
            shouldCapitalize = true                                      // absolute field start
        } else if let last = trimmed.last, ".?!…".contains(last) {
            shouldCapitalize = true                                      // after sentence break
        } else if let last = trimmed.last, ",;:)]}/".contains(last) {
            shouldCapitalize = false                                     // after mid-sentence punct
        } else if following?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            shouldCapitalize = false                                     // mid-sentence insertion
        } else {
            return text                                                  // no strong rule: keep LLM output
        }

        return shouldCapitalize
            ? first.uppercased() + text.dropFirst()
            : first.lowercased() + text.dropFirst()
    }

    // MARK: - Duplicate Punctuation

    /// Removes terminal punctuation when it duplicates or conflicts with what follows.
    /// Rules: same punct already follows → remove; period before comma/semicolon → remove.
    private static func removeDuplicatePunctuation(_ text: String, following: String?) -> String {
        guard
            let following, !following.isEmpty,
            let last = text.last,
            let followFirst = following.trimmingCharacters(in: .whitespaces).first
        else { return text }

        if ".?!".contains(last) && last == followFirst { return String(text.dropLast()) }
        if last == "." && ",;".contains(followFirst)   { return String(text.dropLast()) }

        return text
    }
}
