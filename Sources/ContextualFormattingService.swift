import Foundation

// MARK: - ContextualFormattingService

/// Applies deterministic post-LLM formatting using the surrounding cursor context (AX).
/// Rules are applied strictly in the order: Normalization -> Punctuation -> Capitalization -> Spacing.
enum ContextualFormattingService {

    static func format(
        _ insertedText: String,
        precedingText: String?,
        followingText: String?,
        selectedText: String? = nil,
        cursorPosition: String? = nil
    ) -> String {
        // Log the exact values of surrounding context.
        print("[ContextualFormattingService] format() called. precedingText: '\(precedingText ?? "nil")', followingText: '\(followingText ?? "nil")'")

        // --- Normalization ---
        // Remove surrounding spaces.
        var text = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        
        let prec = precedingText ?? ""
        let fol = followingText ?? ""
        let folTrimmed = fol.trimmingCharacters(in: .whitespaces)
        let folFirstNonSpace = folTrimmed.first
        
        let sel = selectedText ?? ""
        
        let precTrimmed = prec.trimmingCharacters(in: .whitespaces)
        let precLastNonSpace = precTrimmed.last
        
        let isReplacement = !sel.isEmpty

        // --- Punctuation cleanup ---
        
        // No period in the middle of a sentence.
        if !prec.isEmpty, let pLast = precLastNonSpace, !".?!…".contains(pLast), text.hasSuffix(".") {
            text.removeLast()
        }
        
        // Period before these symbols is never correct.
        if text.hasSuffix("."), let f = folFirstNonSpace, "—,;".contains(f) {
            text.removeLast()
        }
        
        // Collapse duplicate punctuation.
        if let last = text.last, ".?!".contains(last), let f = folFirstNonSpace, last == f {
            text.removeLast()
        }
        
        // Standardize ellipsis: only exactly "..." is kept. Any other runs become ".".
        text = text.replacingOccurrences(of: "(?<!\\.)\\.{4,}(?!\\.)", with: ".", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?<!\\.)\\.{2}(?!\\.)", with: ".", options: .regularExpression)
        
        // Avoid "word., nextWord" when the user overwrites a fragment.
        if isReplacement, let last = text.last, ".,;:!?…".contains(last), let f = folFirstNonSpace, f.isLetter || f.isNumber {
            text.removeLast()
        }
        
        // Keep multiple exclamation marks (implicitly handled).

        if text.isEmpty { return "" }

        // --- Capitalization (priority order, first match wins) ---
        var shouldCapitalize: Bool? = nil
        
        if prec.isEmpty {
            // Uppercase at the very beginning.
            shouldCapitalize = true
        } else if prec.range(of: #"(?:^|\n)\s*(?:[-*•–]|[a-zA-Z0-9]+[\.\)])\s+$"#, options: .regularExpression) != nil {
            // Uppercase after bullet/numbered list.
            shouldCapitalize = true
        } else if prec.hasSuffix("\n") {
            // Uppercase after line break.
            shouldCapitalize = true
        } else if let last = precLastNonSpace, ".?!…".contains(last) {
            // Uppercase after end of sentence.
            shouldCapitalize = true
        } else if let last = precLastNonSpace, ",;:".contains(last) {
            // Lowercase after these punctuation marks.
            shouldCapitalize = false
        } else if let last = precLastNonSpace, ")]}".contains(last) {
            // Lowercase after a closing bracket.
            shouldCapitalize = false
        } else if let last = precLastNonSpace, "/—".contains(last) {
            // Lowercase after slash/dash, with leading-dash exception.
            if last == "—" && precTrimmed.count == 1 {
                shouldCapitalize = true
            } else {
                shouldCapitalize = false
            }
        } else if let last = prec.last, "\"'".contains(last) {
            // Capitalize only when the quote follows the end of a sentence.
            let beforeQuote = prec.dropLast().trimmingCharacters(in: .whitespaces)
            if let charBefore = beforeQuote.last, ".?!…\n".contains(charBefore) {
                shouldCapitalize = true
            } else {
                shouldCapitalize = false
            }
        } else {
            // Default to lowercase when continuing a sentence.
            shouldCapitalize = false
        }
        
        if let cap = shouldCapitalize {
            if let firstAlphaIndex = text.firstIndex(where: { $0.isLetter }) {
                let firstAlpha = text[firstAlphaIndex]
                let replacement = cap ? firstAlpha.uppercased() : firstAlpha.lowercased()
                text.replaceSubrange(firstAlphaIndex...firstAlphaIndex, with: replacement)
            }
        }
        
        // --- Spacing ---
        var leadingSpace = ""
        
        let textFirstNonSpace = text.first { !$0.isWhitespace }
        
        let openingPunct = CharacterSet(charactersIn: "({[“‘\"'")
        let closingPunct = CharacterSet(charactersIn: ")]},.!?;:")
        
        // Guarantees a normal word gap.
        if let pLast = precLastNonSpace, let tFirst = textFirstNonSpace {
            if (pLast.isLetter || pLast.isNumber) && (tFirst.isLetter || tFirst.isNumber) {
                leadingSpace = " "
            }
        }
        
        // Standard spacing after these marks.
        if let pLast = precLastNonSpace, ",;:.?!…".contains(pLast) {
            leadingSpace = " "
        }
        
        // Avoid space before "(", "[", "{", quotes, etc.
        if let pLast = precLastNonSpace, let scalar = UnicodeScalar(String(pLast)), openingPunct.contains(scalar) {
            leadingSpace = ""
        }
        
        // Avoid space before ")", "]", "}", ".", ",", etc.
        if let tFirst = textFirstNonSpace, let scalar = UnicodeScalar(String(tFirst)), closingPunct.contains(scalar) {
            leadingSpace = ""
        }
        
        // No space before closing punctuation in the following text.
        if let fFirst = folFirstNonSpace, let scalar = UnicodeScalar(String(fFirst)), closingPunct.contains(scalar) {
            // Previously handled by trailingSpace
        }
        
        // Guarantees clean junction when overwriting selected text.
        if isReplacement {
            // We already trimmed insertedText, so it doesn't start with space.
            // If preceding ends with space, we don't add leadingSpace to avoid duplicates.
            if prec.hasSuffix(" ") {
                leadingSpace = ""
            }
        }
        
        // Handle pre-existing document spaces safely.
        if let last = prec.last, last.isWhitespace {
            leadingSpace = ""
        }
        
        // Preserve selected spaces: if the user selected a leading or trailing space,
        // we must restore it because the system paste replaces the entire selection.
        if !sel.isEmpty {
            if sel.hasPrefix(" ") && leadingSpace.isEmpty && !prec.hasSuffix(" ") {
                leadingSpace = " "
            }
            if sel.hasSuffix(" ") && !text.hasSuffix(" ") && !fol.hasPrefix(" ") {
                text += " "
            }
        }
        
        // Normalizes internal spacing.
        var finalString = leadingSpace + text
        finalString = finalString.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        
        return finalString
    }
}
