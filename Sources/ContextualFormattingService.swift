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
        if let preceding = preceding {
            if preceding.isEmpty {
                // Empty field: capitalize.
                shouldCapitalize = true
            } else if endsWithSentenceBreak(preceding) {
                // After ". " or ".\n" or similar: capitalize.
                shouldCapitalize = true
            } else if endsWithListMarker(preceding) {
                // After "- ", "* ", "1. ", "a) " etc.: capitalize.
                shouldCapitalize = true
            } else {
                // Mid-sentence: lowercase.
                shouldCapitalize = false
            }
        } else {
            // No AX context: capitalize (matches original LLM behavior for standalone utterances).
            shouldCapitalize = true
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
        let wordCount = t.reversed().prefix(while: { !$0.isWhitespace }).count
        return wordCount >= 1 && wordCount <= 4
    }

    // MARK: - Smart spacing

    /// Determines if a leading space is needed between `preceding` and `text`.
    private static func needsLeadingSpace(text: String, preceding: String?) -> Bool {
        // If we don't know the context, we shouldn't guess leading spaces (user might have typed a space manually).
        guard let preceding = preceding, !preceding.isEmpty else { return false }
        
        guard let precLast = preceding.unicodeScalars.last,
              let textFirst = text.unicodeScalars.first else { return false }
              
        // If the preceding text already ends in whitespace, no space needed.
        if CharacterSet.whitespacesAndNewlines.contains(precLast) {
            return false
        }
        
        // If the NEW text STARTS with punctuation that attaches to the left (like , . ! ? ; :), no space.
        if ",.!?;:".unicodeScalars.contains(textFirst) {
            return false
        }
        
        // If preceding text ends in an opening bracket/quote, we usually don't want a space.
        if "([{".unicodeScalars.contains(precLast) {
            return false
        }
        
        // Otherwise, add a space to separate the new dictation from the existing text.
        return true
    }

    /// Determines if a trailing space is needed after `text`, considering `following`.
    private static func needsTrailingSpace(text: String, following: String?) -> Bool {
        // Wispr/FreeFlow usually adds a space ONLY if it ends in . ! ? so the NEXT dictation is separated.
        guard let textLast = text.last, ".!?".contains(textLast) else { return false }
        
        // If we don't have context (or at end of document), fallback to old behavior: append space after .!?
        guard let following = following, !following.isEmpty else { 
            return true 
        }
        
        guard let follFirst = following.unicodeScalars.first else { return true }
        
        // If the following text ALREADY starts with a space or newline, we don't need to add one.
        if CharacterSet.whitespacesAndNewlines.contains(follFirst) {
            return false
        }
        
        // If the following text is a closing bracket, no space. "Hello.)"
        if ")]}".unicodeScalars.contains(follFirst) {
            return false
        }
        
        return true
    }
}
