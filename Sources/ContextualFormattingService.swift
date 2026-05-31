import Foundation

// MARK: - ContextualFormattingService

/// Applies deterministic post-LLM formatting before text is written to the clipboard.
/// Operates on the LLM-cleaned transcript using AX context from AccessibilityTextReader.
/// When context is nil, each rule falls back to a safe default (matching original behavior).
enum ContextualFormattingService {

    // MARK: - Public API

    /// Main entry point. Applies formatting rules in order:
    ///   1. Strip trailing whitespace (prevent double-spacing with smart spacing)
    ///   2. Adjust first-character capitalization based on what precedes the cursor
    ///   3. Remove inappropriate terminal punctuation based on what follows the cursor
    ///   4. Compute leading/trailing smart spacing
    ///
    /// Returns the formatted text and the spacing to add (leading, trailing).
    static func format(
        _ text: String,
        precedingText: String?,
        followingText: String?
    ) -> (text: String, leadingSpace: String, trailingSpace: String) {
        guard !text.isEmpty else { return (text, "", "") }

        var result = stripTrailingWhitespace(text)
        guard !result.isEmpty else { return (result, "", "") }

        result = adjustCapitalization(result, preceding: precedingText)
        result = adjustTrailingPunctuation(result, following: followingText)

        let leading  = needsLeadingSpace(text: result, preceding: precedingText) ? " " : ""
        let trailing = needsTrailingSpace(text: result, following: followingText) ? " " : ""

        return (result, leading, trailing)
    }

    // MARK: - Trailing whitespace

    /// Strips all trailing whitespace variants so smart spacing can take over cleanly.
    private static func stripTrailingWhitespace(_ text: String) -> String {
        var result = text
        while let last = result.unicodeScalars.last {
            switch last.value {
            case 0x0020, // SPACE
                 0x00A0, // NO-BREAK SPACE
                 0x0009, // TAB
                 0x200B, // ZERO WIDTH SPACE
                 0x200C, // ZERO WIDTH NON-JOINER
                 0x200D, // ZERO WIDTH JOINER
                 0x000A, // LINE FEED
                 0x000D: // CARRIAGE RETURN
                result.removeLast()
            default:
                return result
            }
        }
        return result
    }

    // MARK: - Capitalization

    /// Uppercases or lowercases the first character of `text` based on `preceding`.
    /// Handles four cases: (1) nil context, (2) empty field, (3) after sentence break, (4) mid-sentence.
    private static func adjustCapitalization(_ text: String, preceding: String?) -> String {
        guard let first = text.first else { return text }

        let shouldCapitalize: Bool
        guard let preceding = preceding else {
            // No AX context: capitalize (matches original LLM behavior for standalone utterances).
            shouldCapitalize = true
        } switch preceding.isEmpty {
        case true:
            // Empty field: capitalize.
            shouldCapitalize = true
        default:
            if endsWithSentenceBreak(preceding) {
                // After ". " or ".\n" or similar: capitalize.
                shouldCapitalize = true
            } else if endsWithListMarker(preceding) {
                // After "- ", "* ", "1. ", "a) " etc.: capitalize.
                shouldCapitalize = true
            } else {
                // Mid-sentence: lowercase.
                shouldCapitalize = false
            }
        }

        if shouldCapitalize {
            return first.isLowercase ? text.prefix(1).uppercased() + text.dropFirst() : text
        } else {
            return first.isUppercase ? text.prefix(1).lowercased() + text.dropFirst() : text
        }
    }

    /// True when the text ends with sentence-terminating punctuation (possibly followed by whitespace).
    private static func endsWithSentenceBreak(_ text: String) -> Bool {
        for ch in text.reversed() {
            if ch.isWhitespace { continue }
            return ".!?".contains(ch)
        }
        return false
    }

    /// True when the text ends with a list-item marker followed by whitespace.
    /// Covers: "- ", "* ", "• ", "1. ", "2) " etc.
    private static func endsWithListMarker(_ text: String) -> Bool {
        // Must end with whitespace (the space after the marker).
        guard let lastChar = text.last, lastChar.isWhitespace else { return false }
        let withoutSpace = text.dropLast()
        guard let markerChar = withoutSpace.last else { return false }

        if "-*•".contains(markerChar) { return true }

        // Closing paren: "1)" "a)"
        if markerChar == ")" {
            if let before = withoutSpace.dropLast().last, before.isNumber || before.isLetter {
                return true
            }
        }

        // Numbered: "1." "2." "10."
        if markerChar == "." {
            let beforeDot = withoutSpace.dropLast()
            if let before = beforeDot.last, before.isNumber { return true }
        }

        return false
    }

    // MARK: - Terminal punctuation

    /// Removes terminal punctuation (. ! ?) from `text` when `following` indicates
    /// the cursor is mid-sentence or the existing text already has punctuation there.
    private static func adjustTrailingPunctuation(_ text: String, following: String?) -> String {
        guard let following = following, !following.isEmpty else {
            // No following text: terminal punctuation is appropriate, keep it.
            return text
        }
        guard let lastChar = text.last, ".!?".contains(lastChar) else {
            return text
        }
        // Exception: abbreviations like "Dr.", "vs.", "etc." (≤4 chars before the dot).
        if lastChar == "." && isLikelyAbbreviation(text) {
            return text
        }

        let followingFirst = following.unicodeScalars.first
        let followsWordChar = followingFirst.map { CharacterSet.alphanumerics.contains($0) } ?? false
        let followsPunct    = followingFirst.map { ".!?,;:".unicodeScalars.contains($0) } ?? false

        if followsWordChar || followsPunct {
            return String(text.dropLast())
        }
        return text
    }

    /// A terminal period is likely an abbreviation when the word before it is ≤ 4 characters.
    private static func isLikelyAbbreviation(_ text: String) -> Bool {
        var t = text
        guard t.last == "." else { return false }
        t.removeLast()
        let word = t.suffix(while: { !$0.isWhitespace })
        return word.count >= 1 && word.count <= 4
    }

    // MARK: - Smart spacing

    /// Add a leading space when both sides start/end with word characters.
    private static func needsLeadingSpace(text: String, preceding: String?) -> Bool {
        guard let preceding = preceding, !preceding.isEmpty else { return false }
        guard let precLast = preceding.unicodeScalars.last,
              let textFirst = text.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(precLast)
            && (CharacterSet.alphanumerics.contains(textFirst)
                || textFirst.value == 0x0022   // "
                || textFirst.value == 0x2018   // '
                || textFirst.value == 0x201C)  // "
    }

    /// Add a trailing space when the following text starts with a word character.
    /// When followingText is nil, falls back to the original heuristic (space after .!?).
    private static func needsTrailingSpace(text: String, following: String?) -> Bool {
        guard let following = following else {
            // Original behavior: space after sentence-ending punctuation.
            return text.last.map { ".!?".contains($0) } ?? false
        }
        guard !following.isEmpty else { return false }
        guard let textLast = text.unicodeScalars.last,
              let followFirst = following.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(textLast)
            && CharacterSet.alphanumerics.contains(followFirst)
    }
}
