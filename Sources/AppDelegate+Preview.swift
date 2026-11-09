import AppKit
import SwiftUI

/// Thumbnails and the large preview for the current panel session.
extension AppDelegate {
    func preparePreviews(_ handles: [WindowHandle]) {
        let generation = showGeneration
        let priorities = previewPriorities()
        capture.prepare(handles, prioritized: priorities) { [weak self] id, image in
            guard let self, self.showing, self.showGeneration == generation else { return }
            self.state.storePreview(id, image: image)
            if !self.firstPreviewRecorded {
                self.firstPreviewRecorded = true
                RuntimeDiagnostics.shared.record("first_fresh_preview", since: self.showStarted)
            }
        }
        if previewPanel?.isVisible == true || state.searchVisible, let selected = state.selected { capture.request(selected, full: true) }
    }
    func previewPriorities() -> [String] {
        guard state.style == .thumbnails || state.searchVisible || previewPanel?.isVisible == true || state.settings.advanced.autoPreview else { return [] }
        var ids = state.selected.map { [$0.id] } ?? []
        if state.style == .thumbnails && !state.searchVisible { ids += state.items.filter { state.visiblePreviewIDs.contains($0.id) && $0.id != state.selected?.id }.map(\.id) }
        return ids
    }
    func requestSelectedPreview() {
        guard showing, !state.isDemo,
              state.style == .thumbnails || state.searchVisible || previewPanel?.isVisible == true || state.settings.advanced.autoPreview,
              let selected = state.selected else { return }
        capture.request(selected)
        if previewPanel?.isVisible == true || state.searchVisible { capture.request(selected, full: true) }
    }
    func togglePreview() {
        if previewPanel?.isVisible == true { previewPanel?.orderOut(nil); state.zoomImage = nil; syncActivityTimers(); return }
        state.sticky = true
        showPreview(automatic: false)
    }
    func updateAutomaticPreview() {
        guard showing, !state.loading, state.settings.advanced.autoPreview else { return }
        if state.selected == nil { previewPanel?.orderOut(nil); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.showing, self.state.settings.advanced.autoPreview else { return }
            self.showPreview(automatic: true)
        }
    }
    func showPreview(automatic: Bool) {
        guard let selected = state.selected else { return }
        if previewPanel == nil {
            let window = PreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "一瞥 · 大图预览"
            window.hidesOnDeactivate = false; window.hasShadow = true; window.isOpaque = false; window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.contentView = materialView(NSHostingView(rootView: ZoomPreviewView(state: state).frame(maxWidth: .infinity, maxHeight: .infinity)))
            previewPanel = window
        }
        let frame = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let width = frame.width * 0.82, height = frame.height * 0.80
        previewPanel?.appearance = panel.appearance
        // A manual preview covers the switcher; an automatic one sits just behind it.
        previewPanel?.level = NSWindow.Level(rawValue: panel.level.rawValue + (automatic ? -1 : 1))
        previewPanel?.setFrame(NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height), display: true)
        let wasVisible = previewPanel?.isVisible == true
        let fadeIn = state.settings.advanced.previewFadeIn && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        previewPanel?.alphaValue = fadeIn && !wasVisible ? 0 : 1
        previewPanel?.orderFrontRegardless()
        if !wasVisible && fadeIn {
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.12; previewPanel?.animator().alphaValue = 1 }
        }
        // Ask for a sharp frame now that the preview is visible; the thumbnail stands in until it arrives.
        if !state.isDemo { capture.request(selected); capture.request(selected, full: true) }
        syncActivityTimers()
    }
}
