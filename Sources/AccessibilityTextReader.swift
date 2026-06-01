import Foundation
import ApplicationServices
import AppKit

// MARK: - SurroundingTextSnapshot

/// Text context captured around the cursor from the focused text field.
/// All fields are optional; nil means the app does not expose accessible text.
struct SurroundingTextSnapshot {
    /// Up to N characters before the cursor (or selection start).
    let precedingText: String?
    /// Up to N characters after the selection end (never includes selected text).
    let followingText: String?
    /// Semantic position of the cursor within the field.
    let cursorPosition: CursorPosition

    enum CursorPosition: String {
        case start    // index 0
        case middle   // somewhere in the body
        case end      // at or past the last character
        case empty    // field has no text
        case unknown  // AX API did not expose position info
    }

    /// True when at least one side of the cursor is readable.
    var hasContext: Bool { precedingText != nil || followingText != nil }
}

// MARK: - AccessibilityTextReader

/// Reads text surrounding the cursor via the macOS Accessibility API.
///
/// Covers:
/// - Native AppKit controls (NSTextView, NSTextField, etc.)
/// - Electron / Chromium web views (VS Code, Slack, Notion, Linear…)
/// - Browser text fields (Safari, Chrome, Firefox)
/// - Qt and Java/Swing apps via their respective AX bridges
/// - Terminal emulators (Terminal.app, iTerm2) — limited, field-level only
///
/// Falls back gracefully: returns nil values for unsupported apps.
enum AccessibilityTextReader {

    // MARK: Public API

    /// Synchronous read — use when async is not available (e.g., collectSelectionSnapshot).
    static func readSurroundingText(
        from appElement: AXUIElement,
        maxBefore: Int = 300,
        maxAfter: Int = 400
    ) -> SurroundingTextSnapshot {
        guard let focused = focusedElement(in: appElement) else {
            return .init(precedingText: nil, followingText: nil, cursorPosition: .unknown)
        }
        // Fallback cannot be used synchronously.
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
           let _ = valueRef as? String {
            // For sync reads, we can't await. We just return a dummy if it fails.
        }
        return .init(precedingText: nil, followingText: nil, cursorPosition: .unknown)
    }

    /// Async read that auto-syncs the AX tree for Electron/web views before reading.
    /// Always prefer this variant inside async contexts (e.g., collectContext).
    static func readSurroundingTextWithSync(
        from appElement: AXUIElement,
        maxBefore: Int = 300,
        maxAfter: Int = 400
    ) async -> SurroundingTextSnapshot {
        guard let focused = focusedElement(in: appElement) else {
            return .init(precedingText: nil, followingText: nil, cursorPosition: .unknown)
        }

        let initial = await extract(from: focused, maxBefore: maxBefore, maxAfter: maxAfter)

        // Only sync if this looks like a web/Electron element with a potentially stale AX tree.
        guard isWebOrElectronElement(focused) else { return initial }
        
        // Safety guard: Do not run forceSyncAndRead if the user has an active selection.
        // Doing so would use Cmd+Shift+Left and Right Arrow, which destroys the active selection.
        if hasActiveSelection(focused) {
            return initial
        }

        return await syncWebAXTree(
            appElement: appElement,
            focused: focused,
            current: initial,
            maxBefore: maxBefore,
            maxAfter: maxAfter
        )
    }

    /// Returns true when the focused element belongs to a web/Electron/browser view.
    /// Detection is based on non-standard AX attribute name prefixes used by Chromium and WebKit.
    static func isWebOrElectronElement(_ element: AXUIElement) -> Bool {
        var namesRef: CFArray?
        guard AXUIElementCopyAttributeNames(element, &namesRef) == .success,
              let names = namesRef as? [String] else { return false }
        // Chromium-based apps expose "AXDOM*" or "AXWeb*" attributes.
        // WebKit (Safari) exposes "AXWeb*" attributes.
        return names.contains(where: { $0.hasPrefix("AXDOM") || $0.hasPrefix("AXWeb") })
    }

    // MARK: Private — AX tree sync (Electron / browser hack)

    /// Forces the AX tree to refresh by injecting a zero-net-movement key pair.
    /// This is invisible to the user but causes the web engine to flush pending
    /// AX mutations before we re-read the text value.
    ///
    /// - Warning: Must never be called when there is an active text selection,
    ///   because the keypress would collapse it.
    private static func syncWebAXTree(
        appElement: AXUIElement,
        focused: AXUIElement,
        current: SurroundingTextSnapshot,
        maxBefore: Int,
        maxAfter: Int
    ) async -> SurroundingTextSnapshot {
        // Skip if the user has text selected — the keypress would collapse it.
        guard !hasActiveSelection(focused) else { return current }

        let source = CGEventSource(stateID: .hidSystemState)

        // Pick direction: move toward the side that has room, then reverse.
        // atStart = cursor at position 0, so move right first; otherwise move left first.
        let atStart = current.cursorPosition == .start || current.precedingText == nil
        let firstKey: CGKeyCode  = atStart ? 124 : 123   // → or ←
        let secondKey: CGKeyCode = atStart ? 123 : 124   // ← or →

        sendKey(source, firstKey,  keyDown: true)
        sendKey(source, firstKey,  keyDown: false)
        sendKey(source, secondKey, keyDown: true)
        sendKey(source, secondKey, keyDown: false)

        // 100 ms is much safer for most web engines to flush AX mutations.
        try? await Task.sleep(nanoseconds: 100_000_000)

        return await extract(from: focused, maxBefore: maxBefore, maxAfter: maxAfter)
    }

    // MARK: - Private — Clipboard Fallback

    /// Uses Cmd+Shift+Left to copy the preceding line text when AX API fails to expose the text area value.
    /// Safely guarded to NEVER trigger if the user has an active text selection.
    private static func extractViaClipboardFallback(_ element: AXUIElement) async -> SurroundingTextSnapshot {
        // Safety guard: Do not destroy the user's active selection.
        if hasActiveSelection(element) {
            return .init(precedingText: nil, followingText: nil, cursorPosition: .unknown)
        }

        let pasteboard = NSPasteboard.general
        let originalItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let newItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            return newItem
        }

        let source = CGEventSource(stateID: .hidSystemState)

        // 1. Select to beginning of line
        sendKey(source, 123, command: true, shift: true, keyDown: true)
        sendKey(source, 123, command: true, shift: true, keyDown: false)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // 2. Copy selection
        pasteboard.clearContents()
        let initialChangeCount = pasteboard.changeCount
        
        sendKey(source, 8, command: true, shift: false, keyDown: true)
        sendKey(source, 8, command: true, shift: false, keyDown: false)
        
        // Wait for clipboard to populate by polling changeCount (max 300ms)
        var elapsed = 0
        while pasteboard.changeCount == initialChangeCount && elapsed < 300 {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            elapsed += 10
        }

        let precedingText = pasteboard.string(forType: .string)

        // 3. Return cursor to original position (Right arrow un-selects towards the end of selection)
        sendKey(source, 124, command: false, shift: false, keyDown: true)
        sendKey(source, 124, command: false, shift: false, keyDown: false)

        // Restore clipboard
        if let items = originalItems {
            pasteboard.clearContents()
            pasteboard.writeObjects(items)
        }

        return .init(
            precedingText: precedingText?.isEmpty == false ? precedingText : nil,
            followingText: nil,
            cursorPosition: precedingText?.isEmpty == false ? .middle : .unknown
        )
    }

    // MARK: Private — core extraction

    private static func extract(
        from element: AXUIElement,
        maxBefore: Int,
        maxAfter: Int
    ) async -> SurroundingTextSnapshot {
        // Read the complete text content of the field.
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String else {
            return await extractViaClipboardFallback(element)
        }

        guard !fullText.isEmpty else {
            return .init(precedingText: nil, followingText: nil, cursorPosition: .empty)
        }

        let nsText = fullText as NSString
        let totalLength = nsText.length

        // Read the cursor / selection range.
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeVal = rangeRef,
              CFGetTypeID(rangeVal) == AXValueGetTypeID() else {
            // No range info — assume cursor at end; return only precedingText.
            let tail = nsText.substring(from: max(0, totalLength - maxBefore))
            return .init(
                precedingText: tail.isEmpty ? nil : tail,
                followingText: nil,
                cursorPosition: .end
            )
        }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(unsafeBitCast(rangeVal, to: AXValue.self), .cfRange, &cfRange) else {
            return .init(precedingText: nil, followingText: nil, cursorPosition: .unknown)
        }

        // Clamp to valid bounds.
        let selStart = min(max(cfRange.location, 0), totalLength)
        // followingText starts AFTER the selection end so selected text is never included.
        let selEnd   = min(selStart + max(cfRange.length, 0), totalLength)

        // Slice: last maxBefore chars before cursor.
        let beforeStart   = max(0, selStart - maxBefore)
        let precedingSlice = nsText.substring(with: NSRange(location: beforeStart, length: selStart - beforeStart))

        // Slice: first maxAfter chars after selection end.
        let afterLength   = min(maxAfter, totalLength - selEnd)
        let followingSlice = afterLength > 0
            ? nsText.substring(with: NSRange(location: selEnd, length: afterLength))
            : ""

        let position: SurroundingTextSnapshot.CursorPosition
        if selStart == 0          { position = .start }
        else if selStart >= totalLength { position = .end }
        else                      { position = .middle }

        return .init(
            precedingText:  precedingSlice.isEmpty  ? nil : precedingSlice,
            followingText:  followingSlice.isEmpty   ? nil : followingSlice,
            cursorPosition: position
        )
    }

    // MARK: Private — AX helpers

    private static func focusedElement(in appElement: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &ref
        ) == .success,
              let raw = ref,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func hasActiveSelection(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &ref
        ) == .success,
              let val = ref,
              CFGetTypeID(val) == AXValueGetTypeID() else { return false }
        var range = CFRange(location: 0, length: 0)
        AXValueGetValue(unsafeBitCast(val, to: AXValue.self), .cfRange, &range)
        return range.length > 0
    }

    private static func sendKey(_ source: CGEventSource?, _ keyCode: CGKeyCode, command: Bool = false, shift: Bool = false, keyDown: Bool) {
        if let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) {
            var flags: CGEventFlags = []
            if command { flags.insert(.maskCommand) }
            if shift { flags.insert(.maskShift) }
            event.flags = flags
            event.post(tap: .cgSessionEventTap)
        }
    }
}
