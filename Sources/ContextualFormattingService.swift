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

    private static func applyCapitalization(
        _ text: String,
        preceding: String?,
        following: String?
    ) -> String {
        guard let first = text.first, let preceding else { return text }

        let cap = { first.uppercased() + text.dropFirst() }
        let low = { first.lowercased() + text.dropFirst() }

        // RULE 1: List marker -> UPPER
        if preceding.range(of: #"(?:^|\n)\s*(?:[-*•–]|[a-zA-Z0-9]+[\.\)])\s+$"#, options: .regularExpression) != nil {
            return cap()
        }

        // RULE 2: New line or paragraph -> UPPER
        if preceding.hasSuffix("\n") {
            return cap()
        }

        let trimmed = preceding.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.last {
            // RULE 3: After sentence break -> UPPER
            if ".?!…".contains(last) {
                return cap()
            }

            // RULE 4: After comma, semicolon, colon -> LOWER
            if ",;:".contains(last) {
                return low()
            }

            // RULE 5: After closing paren, bracket, brace -> LOWER
            if ")]}".contains(last) {
                return low()
            }

            // RULE 6: After slash or dash -> LOWER (Exception: first char -> UPPER)
            if last == "/" || last == "—" || last == "-" {
                if (last == "—" || last == "-") && trimmed.count == 1 {
                    return cap()
                }
                return low()
            }

            // RULE 7: After opening quote -> INHERIT
            if last == "\"" || last == "'" {
                let beforeQuote = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
                if let charBefore = beforeQuote.last {
                    if ".?!…\n".contains(charBefore) {
                        return cap()
                    } else {
                        return low()
                    }
                } else {
                    return cap()
                }
            }
        }

        // RULE 8: Mid-sentence insertion -> LOWER
        if following?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return low()
        }

        // RULE 9: Absolute start of field -> UPPER
        if preceding.isEmpty {
            return cap()
        }

        return text
    }

    // MARK: - Duplicate Punctuation

    private static func removeDuplicatePunctuation(_ text: String, following: String?) -> String {
        var result = text
        guard let following, !following.isEmpty else { return result }
        let followFirst = following.trimmingCharacters(in: .whitespaces).first

        // REGRA P1: Remover ponto final em inserção no meio de frase
        if result.last == ".", let f = followFirst, f.isLetter || f.isNumber {
            result = String(result.dropLast())
        }

        // REGRA P2: Remover ponto final antes de travessão
        if result.last == ".", let f = followFirst, f == "—" || f == "-" {
            result = String(result.dropLast())
        }

        // REGRA P3: Remover pontuação duplicada
        if let last = result.last, ".?!".contains(last), let f = followFirst, last == f {
            result = String(result.dropLast())
        }

        // REGRA P4: Remover ponto antes de vírgula ou ponto e vírgula
        if result.last == ".", let f = followFirst, ",;".contains(f) {
            result = String(result.dropLast())
        }

        return result
    }
}
