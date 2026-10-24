import Cocoa
import Carbon
import ApplicationServices
import LangSwitchCore

/// A single reused overlay panel that flashes the current input source's glyph
/// at the text caret, falling back to the mouse cursor, after a switch. Main-thread
/// only — it is driven solely by AppDelegate's main-run-loop input-source-change observer.
final class LanguageIndicatorHUD {
    private let panelSize = NSSize(width: 22, height: 15)
    private let cursorOffset: CGFloat = 14
    private let visibleDuration: TimeInterval = 0.9
    private let fadeDuration: TimeInterval = 0.2

    private let panel: NSPanel
    private let label: NSTextField
    private var hideTimer: Timer?
    private var fadeGeneration = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false          // reused panel; never let AppKit free it
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]

        // Solid blue pill matching the native input-source indicator (replaces the
        // former .hudWindow blur). One fixed look, so the color is snapshotted once.
        let background = NSView(frame: NSRect(origin: .zero, size: panelSize))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.systemBlue.cgColor
        background.layer?.cornerRadius = 4
        background.layer?.masksToBounds = true

        label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        panel.contentView = background
    }

    /// Shows the glyph for the given (already-committed) input source and restarts
    /// the auto-hide timer, reusing the same panel if it is still visible.
    func show(for source: TISInputSource) {
        label.stringValue = indicatorGlyph(
            languageCode: primaryLanguage(of: source),
            localizedName: localizedName(of: source)
        )

        let w = panelSize.width
        let h = panelSize.height

        // Prefer the text caret (placed just below-left of it, like the native
        // indicator); fall back to the mouse cursor when Accessibility has no caret.
        let origin: NSPoint
        let screen: NSScreen?
        if let caret = caretScreenRect(),
           let caretScreen = NSScreen.screens.first(where: { $0.frame.intersects(caret) }) {
            screen = caretScreen
            origin = NSPoint(x: caret.minX - w, y: caret.minY - h - cursorOffset)
        } else {
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main
            origin = NSPoint(x: mouse.x - w, y: mouse.y - h - cursorOffset)
        }
        guard let vis = screen?.visibleFrame else { return }
        let x = min(max(origin.x, vis.minX), vis.maxX - w)
        let y = min(max(origin.y, vis.minY), vis.maxY - h)
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        // Cancel any in-flight fade before re-showing. A direct `alphaValue = 1`
        // would be overwritten by a still-running fade animation; the zero-duration
        // animator group retargets it back to fully opaque.
        fadeGeneration += 1
        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        hideTimer = Timer.scheduledTimer(
            withTimeInterval: visibleDuration,
            repeats: false
        ) { [weak self] _ in
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A superseded fade (the panel was re-shown mid-animation) must not
            // hide the just-reshown panel.
            guard let self, self.fadeGeneration == generation else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    /// Caret/selection bounds of the system-focused UI element, in AppKit screen
    /// coordinates (bottom-left origin). Returns nil whenever the Accessibility
    /// API cannot produce a usable rect (no focused element, attribute
    /// unsupported — e.g. secure fields or non-AX apps — or a degenerate rect).
    /// Reads only; the existing tap's Accessibility grant already covers it, so it
    /// never triggers a permission prompt.
    private func caretScreenRect() -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()
        // Bound AX IPC so a hung app cannot stall the main run loop (and the
        // keyboard tap that shares it) while resolving the caret.
        AXUIElementSetMessagingTimeout(systemWide, 0.08)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success,
            let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.08)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success,
            let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }

        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsRef
        ) == .success,
            let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID()
        else { return nil }
        var axRect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &axRect) else { return nil }

        // A collapsed caret legitimately has zero WIDTH; reject only rects with no
        // height or the all-zero rect some apps return for unsupported ranges.
        guard axRect.height > 0, axRect != .zero else { return nil }

        // AX returns Quartz screen coords (top-left origin of the primary display);
        // flip to AppKit's bottom-left origin using the primary screen's height
        // (the screen whose frame origin is (0,0)), not the caret's screen.
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first
        else { return nil }
        return NSRect(
            x: axRect.minX,
            y: primary.frame.height - axRect.maxY,
            width: axRect.width,
            height: axRect.height
        )
    }

    private func primaryLanguage(of source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return nil
        }
        let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]
        return languages?.first
    }

    private func localizedName(of source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
            return "?"
        }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}
