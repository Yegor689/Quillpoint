import SwiftUI
import AppKit

// MARK: - Inline rich-text field (task titles)

struct RichTitleField: NSViewRepresentable {
    @Binding var rtf: Data
    var font: NSFont = .preferredFont(forTextStyle: .title3)
    var isFocused: Bool
    /// When true (and not being edited), the title is shown struck-through and
    /// dimmed. This is a DISPLAY-ONLY overlay (layout-manager temporary attributes);
    /// the stored RTF is never modified, and editing clears it.
    var isDone: Bool = false
    var onFocus: () -> Void
    var onReturn: () -> Void
    /// Enter pressed with caret at the very start: insert a new task before this one.
    var onReturnAtStart: () -> Void = {}
    var onDeleteIfEmpty: () -> Void
    var onBlurIfEmpty: () -> Void
    var onTab: () -> Void
    var onShiftTab: () -> Void
    var onNavigateUp: () -> Void
    var onNavigateDown: () -> Void
    /// Persists the edited text to disk. Typing only updates the model in memory (via the
    /// `rtf` binding); without this, an edit is lost on quit/reopen unless some other action
    /// flushes the context. Called on end-editing (focus loss) and debounced while typing.
    var onCommit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RichInlineTextView {
        let tv = RichInlineTextView()
        tv.delegate = context.coordinator
        tv.actions = context.coordinator.actions
        tv.isRichText = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.maximumNumberOfLines = 0
        tv.isAutomaticLinkDetectionEnabled = true
        tv.isAutomaticDataDetectionEnabled = true
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.usesFontPanel = true
        tv.allowsUndo = true
        // Stored RTF bakes in a resolved color; remap it to the active appearance
        // so text saved in one mode stays visible in the other.
        tv.usesAdaptiveColorMappingForDarkAppearance = true
        tv.font = font
        tv.typingAttributes = defaultAttrs(font: font)
        tv.coordinator = context.coordinator
        context.coordinator.textView = tv

        // Make width tracking explicit so layout is identical across macOS versions:
        // the text view fills the scroll view's width and only grows vertically.
        // (AppKit's defaults for these differ between OS releases, which collapsed
        // the field to zero width on some Macs.)
        // No NSScrollView wrapper: a scroll view has no intrinsic height and would
        // swallow the text view's content height, clamping a wrapped title to one
        // line. Returning the text view directly lets its intrinsicContentSize reach
        // SwiftUI so the row grows to fit the wrapped lines.
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        return tv
    }

    func updateNSView(_ tv: RichInlineTextView, context: Context) {
        // Update the action box so RichInlineTextView always calls fresh closures
        context.coordinator.actions.onReturn        = onReturn
        context.coordinator.actions.onReturnAtStart = onReturnAtStart
        context.coordinator.actions.onDeleteIfEmpty = onDeleteIfEmpty
        context.coordinator.actions.onBlurIfEmpty   = onBlurIfEmpty
        context.coordinator.actions.onTab           = onTab
        context.coordinator.actions.onShiftTab      = onShiftTab
        context.coordinator.actions.onFocus         = onFocus
        context.coordinator.actions.onNavigateUp    = onNavigateUp
        context.coordinator.actions.onNavigateDown  = onNavigateDown
        // Also keep parent fresh for save() which writes back to @Binding
        context.coordinator.parent = self

        // "Being edited" = first responder OR an open editing session (see isEditingSession):
        // the session flag keeps the overwrite branch below from clobbering just-typed text
        // during a transient re-render where first responder bounces.
        let isEditing = tv.window?.firstResponder === tv || context.coordinator.isEditingSession
        if !isEditing {
            let desired = attrStr(from: rtf, font: font)
            if tv.attributedString().string != desired.string || tv.textStorage?.length == 0 {
                context.coordinator.isUpdating = true
                tv.textStorage?.setAttributedString(desired)
                context.coordinator.isUpdating = false
                tv.invalidateIntrinsicContentSize()
            }
            // Show completed titles struck-through + dimmed, as a display-only
            // overlay that leaves the stored RTF untouched.
            tv.setCompletedAppearance(isDone)
        } else {
            // While editing, never show the completed styling — edit normally.
            tv.setCompletedAppearance(false)
        }

        // Caret-to-end must happen ONLY on the false→true transition of isFocused (a
        // newly created or navigated-to row taking focus programmatically). While a row
        // stays focused, unrelated re-renders — e.g. hover revealing the row's action
        // buttons, which relayouts the field and can bounce first responder — must NOT
        // touch the caret, or it jumps to the end of the title away from where the user
        // clicked (issue #37).
        let focusJustGained = isFocused && !context.coordinator.wasFocused
        context.coordinator.wasFocused = isFocused

        // Only PROGRAMMATICALLY take first responder on the false→true transition of
        // isFocused — a row newly created or navigated-to. Grabbing it on EVERY re-render
        // where isFocused is merely still true stole focus back when the user clicked away:
        // a re-render (e.g. from onCommit's save) ran updateNSView on the old row while its
        // isFocused hadn't yet flipped false, and makeFirstResponder yanked focus home. This
        // hit SUBTASKS specifically — nested inside the parent row's recomputing ForEach, the
        // subtask got one extra render pass with stale isFocused before the new focusedID
        // reached it; top-level rows updated in the same pass and escaped. Gating on
        // focusJustGained fixes both, and matches what the caret-to-end already required.
        if isFocused && focusJustGained {
            DispatchQueue.main.async {
                guard let window = tv.window, window.firstResponder !== tv else { return }
                if let cur = window.firstResponder, !(cur is RichInlineTextView), cur is NSText { return }
                window.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
            }
        }
    }

    // MARK: Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTitleField
        let actions: ActionBox
        weak var textView: NSTextView?
        var isUpdating = false
        // Tracks the previous isFocused so caret-to-end fires only on the false→true
        // transition, not on re-renders while the row stays focused (issue #37).
        var wasFocused = false
        // True while editing (begin→end). Unlike an instantaneous `firstResponder === tv`
        // check, it stays true across the transient re-renders while typing — e.g. a
        // subtask's parent row recomputing its ForEach, during which first responder
        // briefly bounces. updateNSView guards the rtf→textStorage overwrite on this so
        // that re-render can't clobber the just-typed text ("subtask turns blank" bug).
        var isEditingSession = false
        // Debounces the disk-persist while typing, so we don't call ModelContext.save()
        // on every keystroke but still persist shortly after the user pauses.
        private var commitWorkItem: DispatchWorkItem?

        init(_ parent: RichTitleField) {
            self.parent = parent
            self.actions = ActionBox(parent: parent)
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditingSession = true
            actions.onFocus()
        }

        /// Records where the pending edit lands, BEFORE it happens. This is the only
        /// reliable source for "what did the user just type and where": by the time
        /// textDidChange runs, the text view's selectedRange may not yet reflect the
        /// insertion, so deriving the position from the selection there silently misfires.
        /// `nil` means the change didn't come from typing (programmatic set, paste, …).
        private var pendingInsertEnd: Int?

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString: String?) -> Bool {
            // applyPattern calls tv.shouldChangeText(in:) to register its rewrite for undo,
            // which re-enters this method with the REWRITE's range. Verified against a live
            // NSTextView: it would overwrite the typing position we're here to record.
            // Ignore those; only genuine user edits update it.
            guard !isAutoFormatting else { return true }
            // End of the text once the replacement is applied.
            pendingInsertEnd = replacementString.map { range.location + ($0 as NSString).length }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let tv = notification.object as? NSTextView else { return }
            let insertEnd = pendingInsertEnd
            pendingInsertEnd = nil
            applyMarkdownShortcuts(tv, insertEnd: insertEnd)
            tv.checkTextInDocument(nil)
            tv.invalidateIntrinsicContentSize()
            save(tv)                 // model (in-memory) updated every keystroke
            scheduleCommit()         // …then flushed to disk shortly after typing pauses
        }

        /// Persist to disk (via onCommit → TaskStore.save) when editing ends — focus loss,
        /// the row being torn down, or the window resigning key. This is the guaranteed
        /// commit point for a typed title; the debounce is just a best-effort earlier flush.
        ///
        /// The context.save() is dispatched to the NEXT runloop tick, NOT run inline here.
        /// Running it synchronously inside the end-editing notification mutates the model
        /// mid-focus-transition, forcing an immediate re-render while first responder is
        /// moving to the newly clicked row — which let the old row's updateNSView re-grab
        /// focus (you couldn't click away from a subtask being edited). Deferring lets the
        /// focus change settle first, then persists.
        func textDidEndEditing(_ notification: Notification) {
            isEditingSession = false
            if let tv = notification.object as? NSTextView { save(tv) }
            commitWorkItem?.cancel()
            commitWorkItem = nil
            DispatchQueue.main.async { [weak self] in self?.parent.onCommit() }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            openLink(link)
        }

        func save(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let attrStr = NSAttributedString(attributedString: storage)
            if let data = try? attrStr.data(from: NSRange(location: 0, length: attrStr.length),
                                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                parent.rtf = data
            }
        }

        /// Writes the current text to the model AND flushes it to disk immediately.
        /// Called before structural actions (Tab/Enter) so the typed title is durable even
        /// if the row is reparented or the user quits right after.
        func forceSave() {
            if let tv = textView { save(tv) }
            commitNow()
        }

        /// Schedules a debounced disk commit ~0.6s after the last keystroke.
        private func scheduleCommit() {
            commitWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.parent.onCommit() }
            commitWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
        }

        /// Cancels any pending debounce and commits to disk right now.
        private func commitNow() {
            commitWorkItem?.cancel()
            commitWorkItem = nil
            parent.onCommit()
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard let tv = textView as? RichInlineTextView else { return false }
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                tv.handleInsertNewline(); return true
            case #selector(NSResponder.insertTab(_:)):
                tv.handleTab(); return true
            case #selector(NSResponder.insertBacktab(_:)):
                tv.handleShiftTab(); return true
            case #selector(NSResponder.deleteBackward(_:)):
                return tv.handleDeleteBackward()
            default:
                return false
            }
        }

        /// Guards against re-entry: the rewrite calls didChangeText() to register undo,
        /// which posts the change notification that lands back in textDidChange. Without
        /// this the autoformat would run a second, pointless pass (harmless — the markers
        /// are already consumed — but it re-saves and re-checks spelling every keystroke).
        private var isAutoFormatting = false

        /// Converts `**bold**` / `_italic_` once the user types the space or newline that
        /// closes them. `insertEnd` is where that typed text ends, captured in
        /// shouldChangeTextIn before the edit landed.
        ///
        /// It used to trigger on `storage.string.last` — the final character of the WHOLE
        /// field — so the shortcut only fired when the caret happened to be at the very
        /// end. Styling something mid-title silently did nothing, which is the "only bolds
        /// half the time" report. Reading tv.selectedRange() here instead is NOT a fix:
        /// the selection isn't reliably updated yet when this runs, which broke the feature
        /// outright. The pre-edit range is the one dependable source.
        private func applyMarkdownShortcuts(_ tv: NSTextView, insertEnd: Int?) {
            guard !isAutoFormatting, let storage = tv.textStorage else { return }
            isAutoFormatting = true
            defer { isAutoFormatting = false }

            let ns = storage.string as NSString
            // Fall back to end-of-text when there's no recorded insertion (e.g. a
            // programmatic change), which is the old behaviour and safe.
            let end = min(insertEnd ?? ns.length, ns.length)
            guard end > 0 else { return }
            let typed = ns.substring(with: NSRange(location: end - 1, length: 1))
            guard typed == " " || typed == "\n" else { return }

            // Search only up to the just-typed closer, so a marker further along the line
            // can't pair with one behind the cursor and style a span never delimited.
            let scope = NSRange(location: 0, length: end)
            applyPattern(storage: storage, tv: tv, in: scope,
                         pattern: "\\*\\*(.+?)\\*\\*", trait: .boldFontMask)
            applyPattern(storage: storage, tv: tv, in: scope,
                         pattern: "(?<![*_])_(.+?)_(?![*_])", trait: .italicFontMask)
        }

        private func applyPattern(storage: NSTextStorage, tv: NSTextView, in scope: NSRange,
                                  pattern: String, trait: NSFontTraitMask) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let bounded = NSRange(location: 0, length: min(scope.length, storage.length))
            let matches = regex.matches(in: storage.string, range: bounded)
            guard !matches.isEmpty else { return }
            // Preserve the caret across the rewrite. The caret is the end of the scope (the
            // character just typed), NOT tv.selectedRange() — the selection isn't reliably
            // updated at this point. Every match sits before it, so the caret shifts left
            // by the markers removed ahead of it. Jumping to storage.length instead — as
            // this used to — threw the cursor to the end of the field mid-title.
            let caret = bounded.length
            var removedBeforeCaret = 0

            // Route the rewrite through shouldChangeText/didChangeText rather than editing
            // the storage directly, so it registers with the text view's undo manager. It
            // used to bypass that entirely: the autoformat was the one text mutation in the
            // app ⌘Z couldn't reach, so pressing undo skipped past it and reverted the
            // typing instead — and since the shortcut consumes the ** markers, there was no
            // way back to literal asterisks at all. Grouped into a single undo action so one
            // ⌘Z reverts the whole autoformat.
            tv.undoManager?.beginUndoGrouping()
            defer { tv.undoManager?.endUndoGrouping() }

            for match in matches.reversed() {
                let full = match.range(at: 0)
                let inner = match.range(at: 1)
                guard Range(inner, in: storage.string) != nil else { continue }
                // Keep the inner run's existing attributes (link, colour, …) and change only
                // the font, the way the paste handler does. Rebuilding from a plain String
                // dropped everything but the font.
                let replacement = NSMutableAttributedString(
                    attributedString: storage.attributedSubstring(from: inner))
                let base = storage.attribute(.font, at: inner.location, effectiveRange: nil) as? NSFont
                    ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let newFont = NSFontManager.shared.font(withFamily: base.familyName ?? "System",
                                                        traits: trait, weight: 5, size: base.pointSize) ?? base
                replacement.addAttribute(.font, value: newFont,
                                         range: NSRange(location: 0, length: replacement.length))
                guard tv.shouldChangeText(in: full, replacementString: replacement.string) else { continue }
                if full.location + full.length <= caret {
                    removedBeforeCaret += full.length - replacement.length
                }
                storage.beginEditing()
                storage.replaceCharacters(in: full, with: replacement)
                storage.endEditing()
                tv.didChangeText()
            }

            let newCaret = max(0, min(storage.length, caret - removedBeforeCaret))
            tv.setSelectedRange(NSRange(location: newCaret, length: 0))
        }
    }
}

// MARK: - ActionBox (reference type so RichInlineTextView always has fresh closures)

final class ActionBox {
    var onReturn:        () -> Void
    var onReturnAtStart: () -> Void
    var onDeleteIfEmpty: () -> Void
    var onBlurIfEmpty:   () -> Void
    var onTab:           () -> Void
    var onShiftTab:      () -> Void
    var onFocus:         () -> Void
    var onNavigateUp:    () -> Void
    var onNavigateDown:  () -> Void

    init(parent: RichTitleField) {
        onReturn        = parent.onReturn
        onReturnAtStart = parent.onReturnAtStart
        onDeleteIfEmpty = parent.onDeleteIfEmpty
        onBlurIfEmpty   = parent.onBlurIfEmpty
        onTab           = parent.onTab
        onShiftTab      = parent.onShiftTab
        onFocus         = parent.onFocus
        onNavigateUp    = parent.onNavigateUp
        onNavigateDown  = parent.onNavigateDown
    }
}

// MARK: - Full rich-text editor (task description)

struct RichDescriptionEditor: NSViewRepresentable {
    @Binding var rtf: Data
    var font: NSFont = .preferredFont(forTextStyle: .body)
    /// Persists the edited note to disk (typing only updates the model in memory). Called
    /// on end-editing and debounced while typing. See RichTitleField.onCommit.
    var onCommit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.isAutomaticLinkDetectionEnabled = true
        tv.isAutomaticDataDetectionEnabled = true
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.usesFontPanel = true
        tv.allowsUndo = true
        tv.usesAdaptiveColorMappingForDarkAppearance = true
        tv.font = font
        tv.typingAttributes = defaultAttrs(font: font)
        tv.autoresizingMask = [.width]
        context.coordinator.textView = tv

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        guard tv.window?.firstResponder !== tv else { return }
        let desired = attrStr(from: rtf, font: font)
        if tv.attributedString().string != desired.string {
            context.coordinator.isUpdating = true
            tv.textStorage?.setAttributedString(desired)
            context.coordinator.isUpdating = false
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichDescriptionEditor
        weak var textView: NSTextView?
        var isUpdating = false
        private var commitWorkItem: DispatchWorkItem?

        init(_ parent: RichDescriptionEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let tv = notification.object as? NSTextView else { return }
            tv.checkTextInDocument(nil)
            guard let storage = tv.textStorage else { return }
            let a = NSAttributedString(attributedString: storage)
            if let data = try? a.data(from: NSRange(location: 0, length: a.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                parent.rtf = data
            }
            scheduleCommit()
        }

        /// Guaranteed disk-commit point: editing ended (focus loss / teardown). Deferred to
        /// the next runloop tick so the save() doesn't re-render mid-focus-transition (see
        /// RichTitleField.Coordinator.textDidEndEditing for why).
        func textDidEndEditing(_ notification: Notification) {
            commitWorkItem?.cancel()
            commitWorkItem = nil
            DispatchQueue.main.async { [weak self] in self?.parent.onCommit() }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            openLink(link)
        }

        private func scheduleCommit() {
            commitWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.parent.onCommit() }
            commitWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
        }

        private func commitNow() {
            commitWorkItem?.cancel()
            commitWorkItem = nil
            parent.onCommit()
        }
    }
}

// MARK: - Helpers

func attrStr(from rtf: Data, font: NSFont) -> NSAttributedString {
    if !rtf.isEmpty,
       let a = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
        return a
    }
    return NSAttributedString(string: "", attributes: defaultAttrs(font: font))
}

func defaultAttrs(font: NSFont) -> [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: NSColor.labelColor]
}

@discardableResult
func openLink(_ link: Any) -> Bool {
    if let url = link as? URL { NSWorkspace.shared.open(url); return true }
    if let str = link as? String, let url = URL(string: str) { NSWorkspace.shared.open(url); return true }
    return false
}

// MARK: - RichInlineTextView

class RichInlineTextView: NSTextView {
    var coordinator: RichTitleField.Coordinator?
    var actions: ActionBox?
    // Set to true when a keypress already handled deletion, so resignFirstResponder doesn't double-fire.
    var deletionHandled = false

    // Reject foreign drags (e.g. a task being dragged to reorder) so their payload
    // can never be inserted into the title as text.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }

    override func resignFirstResponder() -> Bool {
        let empty = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let result = super.resignFirstResponder()
        if result && empty && !deletionHandled { actions?.onBlurIfEmpty() }
        deletionHandled = false
        return result
    }

    override func becomeFirstResponder() -> Bool {
        // Clear the completed overlay the moment editing starts so the user edits the
        // normal title; updateNSView re-applies it after editing ends if still done.
        setCompletedAppearance(false)
        return super.becomeFirstResponder()
    }

    /// Applies or removes a DISPLAY-ONLY strikethrough + dimmed color over the whole
    /// title using the layout manager's temporary attributes. Temporary attributes
    /// affect rendering only — the text storage (and thus the stored RTF) is never
    /// modified, so toggling completion or editing leaves the saved title intact.
    /// Idempotent: safe to call after every text update (it re-applies the overlay,
    /// which a programmatic text reset would otherwise clear).
    func setCompletedAppearance(_ done: Bool) {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let range = NSRange(location: 0, length: (string as NSString).length)
        guard range.length > 0 else { return }
        if done {
            layoutManager.setTemporaryAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor
            ], forCharacterRange: range)
        } else {
            layoutManager.setTemporaryAttributes([:], forCharacterRange: range)
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let c = textContainer, let m = layoutManager else { return super.intrinsicContentSize }
        m.ensureLayout(for: c)
        // Width is governed entirely by SwiftUI's frame (maxWidth: .infinity); reporting
        // an intrinsic width here would let the field collapse to its content width on
        // some macOS versions. Only the height is intrinsic — and it grows with wrapping.
        let f = font ?? NSFont.preferredFont(forTextStyle: .body)
        let height = max(m.usedRect(for: c).height, ceil(m.defaultLineHeight(for: f)))
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    // When the view's width changes (resize, initial layout, or text set
    // programmatically), the number of wrapped lines changes, so the intrinsic
    // height must be recomputed. Without this, a long title stays clamped to the
    // single-line height it had when first measured and the wrapped lines get clipped.
    private var lastLayoutWidth: CGFloat = -1

    override func layout() {
        super.layout()
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: pt)
        if idx < textStorage?.length ?? 0,
           let link = textStorage?.attribute(.link, at: idx, effectiveRange: nil) {
            if openLink(link) { return }
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Let the event bubble up to SwiftUI's context menu instead of showing NSTextView's menu
        nextResponder?.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "b": applyTrait(.boldFontMask); return
            case "i": applyTrait(.italicFontMask); return
            default: break
            }
        }
        let keyCode = event.keyCode
        if keyCode == 126 && isAtFirstLine() { deletionHandled = true; actions?.onNavigateUp();   return }
        if keyCode == 125 && isAtLastLine()  { deletionHandled = true; actions?.onNavigateDown(); return }
        super.keyDown(with: event)
    }

    private func isAtFirstLine() -> Bool {
        guard let layout = layoutManager, let container = textContainer else { return true }
        let caretRect = layout.boundingRect(forGlyphRange: NSRange(location: selectedRange().location, length: 0), in: container)
        let firstLineRect = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        // On first line if caret's minY is within the first line's height
        return caretRect.minY <= firstLineRect.minY + 2
    }

    private func isAtLastLine() -> Bool {
        guard let layout = layoutManager, let container = textContainer else { return true }
        let caretRect = layout.boundingRect(forGlyphRange: NSRange(location: selectedRange().location, length: 0), in: container)
        let lastGlyph = max(0, layout.numberOfGlyphs - 1)
        let lastLineRect = layout.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 0), in: container)
        return caretRect.minY >= lastLineRect.minY - 2
    }

    // Called by the delegate's doCommandBy — routed through ActionBox
    func handleInsertNewline() {
        let empty = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty {
            deletionHandled = true
            actions?.onDeleteIfEmpty()
            return
        }
        // Enter with the caret at the very start (no selection) inserts a new task
        // BEFORE this one, like splitting a list item at the cursor.
        let sel = selectedRange()
        if sel.location == 0 && sel.length == 0 {
            actions?.onReturnAtStart()
        } else {
            actions?.onReturn()
        }
    }

    func handleDeleteBackward() -> Bool {
        let empty = string.isEmpty
        if empty { deletionHandled = true; actions?.onDeleteIfEmpty(); return true }
        return false
    }

    // Commit the typed text to the binding BEFORE indenting/outdenting. Tab arrives via
    // doCommandBy, so the last keystroke's change may not have flushed to task.titleRTF
    // yet — and onTab → TaskStore.indentTask immediately does
    // `task.titleRTF = resizingFontRTF(task.titleRTF, …)`, which would resize the STALE
    // (empty) RTF and overwrite the real title with nothing. forceSave() first makes the
    // model current so indent reads the text the user actually typed. (#blank-on-indent)
    func handleTab()      { coordinator?.forceSave(); actions?.onTab() }
    func handleShiftTab() { coordinator?.forceSave(); actions?.onShiftTab() }

    private func applyTrait(_ trait: NSFontTraitMask) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        if range.length == 0 {
            let cur = typingAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let has = NSFontManager.shared.traits(of: cur).contains(trait)
            let new = has ? NSFontManager.shared.convert(cur, toNotHaveTrait: trait)
                          : NSFontManager.shared.convert(cur, toHaveTrait: trait)
            typingAttributes[.font] = new
            return
        }
        var allHave = true
        storage.enumerateAttribute(.font, in: range) { val, _, stop in
            guard let f = val as? NSFont else { allHave = false; stop.pointee = true; return }
            if !NSFontManager.shared.traits(of: f).contains(trait) { allHave = false; stop.pointee = true }
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { val, sub, _ in
            let f = val as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let new = allHave ? NSFontManager.shared.convert(f, toNotHaveTrait: trait)
                              : NSFontManager.shared.convert(f, toHaveTrait: trait)
            storage.addAttribute(.font, value: new, range: sub)
        }
        storage.endEditing()
        coordinator?.forceSave()
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let baseFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)

        if let data = pb.data(forType: NSPasteboard.PasteboardType("public.html")),
           let a = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            insertRich(inlineOnly(a, baseFont: baseFont)); return
        }
        if let data = pb.data(forType: .rtfd),
           let a = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) {
            insertRich(inlineOnly(a, baseFont: baseFont)); return
        }
        if let data = pb.data(forType: .rtf),
           let a = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            insertRich(inlineOnly(a, baseFont: baseFont)); return
        }
        if let plain = pb.string(forType: .string) {
            insertText(plainCleaned(plain), replacementRange: selectedRange())
            checkTextInDocument(nil)
        }
    }

    private func insertRich(_ a: NSAttributedString) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: a)
        storage.endEditing()
        setSelectedRange(NSRange(location: range.location + a.length, length: 0))
        checkTextInDocument(nil)
        coordinator?.forceSave()
    }

    private func inlineOnly(_ src: NSAttributedString, baseFont: NSFont) -> NSAttributedString {
        let collapsed = NSMutableAttributedString(attributedString: src)
        var i = collapsed.length - 1
        while i >= 0 {
            let ch = (collapsed.string as NSString).character(at: i)
            if ch == 0x0A || ch == 0x0D {
                collapsed.replaceCharacters(in: NSRange(location: i, length: 1), with: " ")
            }
            i -= 1
        }
        let result = NSMutableAttributedString()
        collapsed.enumerateAttributes(in: NSRange(location: 0, length: collapsed.length)) { attrs, sub, _ in
            let text = (collapsed.string as NSString).substring(with: sub)
            let chunk = NSMutableAttributedString(string: text)
            let r = NSRange(location: 0, length: chunk.length)
            let oldFont = attrs[.font] as? NSFont ?? baseFont
            let traits = NSFontManager.shared.traits(of: oldFont)
            let newFont = NSFontManager.shared.font(withFamily: baseFont.familyName ?? "System", traits: traits, weight: 5, size: baseFont.pointSize) ?? baseFont
            chunk.addAttribute(.font, value: newFont, range: r)
            chunk.addAttribute(.foregroundColor, value: NSColor.labelColor, range: r)
            if let link = attrs[.link] { chunk.addAttribute(.link, value: link, range: r) }
            result.append(chunk)
        }
        let s = result.string
        let leading = s.prefix(while: { $0.isWhitespace }).count
        let trailing = s.reversed().prefix(while: { $0.isWhitespace }).count
        let trimLen = max(0, result.length - leading - trailing)
        return trimLen > 0 ? result.attributedSubstring(from: NSRange(location: leading, length: trimLen)) : result
    }

    private func plainCleaned(_ plain: String) -> String {
        plain.components(separatedBy: .newlines)
            .map { line -> String in
                var s = line
                if let r = s.range(of: #"^(\s*[-*+](\s+\[[ xX]\])?\s+|\s*\d+\.\s+)"#, options: .regularExpression) {
                    s.removeSubrange(r)
                }
                return s
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        stripBlockFormatting()
    }

    private func stripBlockFormatting() {
        guard let storage = textStorage else { return }
        storage.beginEditing()
        storage.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: storage.length))
        var i = storage.length - 1
        while i >= 0 {
            let ch = (storage.string as NSString).character(at: i)
            if ch == 0x0A || ch == 0x0D {
                storage.replaceCharacters(in: NSRange(location: i, length: 1), with: " ")
            }
            i -= 1
        }
        storage.endEditing()
    }
}

