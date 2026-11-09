import AppKit
import SwiftUI

/// 一瞥's palette. On Liquid Glass the panel takes its colour from whatever is behind it, so text and
/// fills use the system's semantic styles, which stay legible as the glass changes; amber marks the
/// window you will land on.
enum GlanceDesign {
    /// Amber: selection rings, toggles and the primary button fill. Not for text on light backgrounds.
    static let accent = Color(red: 0xF0 / 255, green: 0xA0 / 255, blue: 0x30 / 255)
    /// Tint for system controls in the panel (segmented controls, switches): a deeper amber, so the white
    /// symbol on a selected segment stays readable. The settings window uses the app's accent colour
    /// instead, compiled from Resources/Assets.xcassets with the same value.
    static let control = adaptive(0xE0891A, 0xEC9628)
    /// Amber dark enough to read as text or a small icon (≥ 4.5:1 in both themes).
    static let accentText = adaptive(0x9A5B00, 0xF5B85A)
    /// Text and icons drawn on an amber fill.
    static let onAccent = Color(red: 0x24 / 255, green: 0x15 / 255, blue: 0)
    /// Text: the system label colours.
    static let ink = Color.primary
    static let secondary = Color.secondary
    /// Selected rows and icon tiles: an amber wash the glass shows through.
    static let selected = adaptive(0xF0A030, 0xF0A030, lightAlpha: 0.2, darkAlpha: 0.26)
    /// The selected card is lit from within: brighter than the glass, which still shows through.
    static let raised = adaptive(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.62, darkAlpha: 0.13)
    static let hover = adaptive(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.3, darkAlpha: 0.07)
    /// Background behind the characters a search matched.
    static let highlight = accent.opacity(0.36)
    /// Dock-style unread badge; dark enough for white text.
    static let badge = Color(red: 0.85, green: 0.19, blue: 0.21)
    /// Opaque backgrounds, only for when no glass is drawn (Reduce Transparency, or macOS 14 and 15).
    static let canvas = adaptive(0xFBFBF9, 0x1E1F23)
    static let surface = adaptive(0xFFFFFF, 0x2B2D32)
    static let line = adaptive(0xE2E1DB, 0x3A3D44)
    static var usesLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    /// Panel corners. Cards sit about 16 points in, so their radius is roughly concentric with it.
    static var panelRadius: CGFloat { usesLiquidGlass ? 30 : 20 }
    static let cardRadius: CGFloat = 14
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.3.1" }

    private static func adaptive(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

/// Clear over glass; an opaque canvas when the system draws no glass or Reduce Transparency is on.
struct GlancePanelBackdrop: ViewModifier {
    var fallback: Color = GlanceDesign.canvas
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background(GlanceDesign.usesLiquidGlass && !reduceTransparency ? Color.clear : fallback)
    }
}

/// The app icon itself, so the panel, settings and Finder always show the same mark.
struct GlanceMark: View {
    var size: CGFloat = 30
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage).resizable().interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Small icon buttons inside the panel. The panel is already glass, so these use a vibrant fill
/// rather than glass of their own: glass on glass reads as clutter.
struct PanelIconButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        PanelIconButton(configuration: configuration, active: active)
    }
    private struct PanelIconButton: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label.font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(GlanceDesign.accentText) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 30, height: 28)
                .background {
                    Capsule(style: .continuous).fill(.quaternary)
                        .opacity(active || configuration.isPressed ? 1 : (hovering && isEnabled ? 0.65 : 0))
                }
                .contentShape(Capsule(style: .continuous))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// Text buttons. On macOS 26 and later these are the system's glass capsules; the primary one is the
/// same glass tinted amber, with dark text because white on amber would be too faint. (The prominent
/// glass style draws a flat rounded rectangle at the small size, which would not match its neighbours.)
struct GlanceButtonStyle: PrimitiveButtonStyle {
    var primary = false
    var compact = false
    @ViewBuilder
    func makeBody(configuration: PrimitiveButtonStyleConfiguration) -> some View {
        if #available(macOS 26.0, *) {
            if primary {
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label.foregroundStyle(GlanceDesign.onAccent)
                }.buttonStyle(.glass).tint(GlanceDesign.accent).controlSize(compact ? .small : .regular)
                    .buttonBorderShape(.capsule)
            } else {
                Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                    .buttonStyle(.glass).controlSize(compact ? .small : .regular).buttonBorderShape(.capsule)
            }
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(LegacyGlanceButtonStyle(primary: primary, compact: compact))
        }
    }
}

/// The flat button for macOS 14 and 15.
private struct LegacyGlanceButtonStyle: ButtonStyle {
    let primary: Bool
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(primary ? GlanceDesign.onAccent : GlanceDesign.ink)
            .padding(.horizontal, compact ? 10 : 14).frame(height: compact ? 28 : 32)
            .background(primary ? GlanceDesign.accent : GlanceDesign.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(primary ? Color.clear : GlanceDesign.line, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct KeyboardHint: View {
    let key: String
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Keycap(text: key)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

/// A floating note over scrolling content: glass on macOS 26 and later, a material before that.
struct GlanceFloatingSurface: ViewModifier {
    var radius: CGFloat = 14
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}
