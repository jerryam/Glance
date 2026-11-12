import AppKit
import SwiftUI

/// A short note that stays on screen for a moment after the panel has closed, such as "已复制 42". It takes no
/// clicks and never becomes the key window, so what is typed next, ⌘V included, goes to the app in front.
final class TransientNotice {
    /// The note's background, from AppDelegate: the same glass as the switcher's, round at the ends.
    var background: ((NSHostingView<TransientNoticeView>, NSRect) -> NSView)?
    private var panel: PreviewPanel?
    private var hosting: NSHostingView<TransientNoticeView>?
    private var generation = 0
    var window: NSWindow? { panel }

    /// Centred where the switcher was a moment ago, or on the screen with the pointer. With no duration it stays
    /// until `hide()`, for the interface pictures.
    func show(_ text: String, symbol: String, around place: NSRect?, appearance: NSAppearance?, duration: TimeInterval? = CopyNotice.duration) {
        let content = TransientNoticeView(text: text, symbol: symbol)
        let measured = NSHostingView(rootView: content).fittingSize
        let size = NSSize(width: min(CopyNotice.widest, max(140, ceil(measured.width))), height: TransientNoticeView.height)
        let panel = self.panel ?? makePanel(size: size)
        hosting?.rootView = content
        panel.appearance = appearance
        let pointer = NSEvent.mouseLocation
        let center = place.map { NSPoint(x: $0.midX, y: $0.midY) }
        let screen = NSScreen.screens.first { $0.frame.contains(center ?? pointer) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let middle = center ?? NSPoint(x: area.midX, y: area.midY)
        let origin = NSPoint(x: min(max(middle.x - size.width / 2, area.minX + 8), area.maxX - size.width - 8),
                             y: min(max(middle.y - size.height / 2, area.minY + 8), area.maxY - size.height - 8))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        generation += 1
        let shown = generation
        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in self?.fade(shown) }
        }
    }

    /// At once, as when the switcher opens again.
    func hide() {
        generation += 1
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }

    private func fade(_ shown: Int) {
        guard shown == generation, let panel, panel.isVisible else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { hide(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, shown == self.generation else { return }
            self.hide()
        })
    }

    private func makePanel(size: NSSize) -> PreviewPanel {
        let frame = NSRect(origin: .zero, size: size)
        let panel = PreviewPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "一瞥 · 提示"
        panel.isFloatingPanel = true
        // Where the switcher was, so at its level.
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: TransientNoticeView(text: "", symbol: "checkmark"))
        panel.contentView = background?(hosting, frame) ?? hosting
        self.panel = panel; self.hosting = hosting
        return panel
    }
}

struct TransientNoticeView: View {
    static let height: CGFloat = 44
    let text: String
    let symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(GlanceDesign.accentText)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(GlanceDesign.ink)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(GlancePanelBackdrop())
        .accessibilityElement(children: .combine)
    }
}
