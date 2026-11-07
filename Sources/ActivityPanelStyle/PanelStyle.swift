import AppKit
import SwiftUI
import ActivityCore

public enum PanelMotion {
    case layout, feedback

    public func animation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: self == .layout ? 0.42 : 0.16)
    }
}

/// Native mapping of the OpenAI Apps SDK UI primitive palette, revision 0f00143.
public enum PanelPalette {
    private static func color(_ light:UInt32,_ dark:UInt32,_ scheme:ColorScheme) -> Color {
        let hex=scheme == .dark ? dark : light
        return Color(.sRGB,red:Double((hex>>16)&255)/255,green:Double((hex>>8)&255)/255,blue:Double(hex&255)/255,opacity:1)
    }

    public static func panel(_ scheme:ColorScheme) -> Color { color(0xf3f3f3,0x181818,scheme) } // gray-75 / sampled Codex background
    public static func card(_ scheme:ColorScheme) -> Color { color(0xffffff,0x303030,scheme) } // gray-0 / gray-300
    public static func preview(_ scheme:ColorScheme) -> Color { color(0xffffff,0x292929,scheme) }
    public static func cardHover(_ scheme:ColorScheme) -> Color { color(0xf0f0f0,0x3b3b3b,scheme) }
    public static func controlHover(_ scheme:ColorScheme) -> Color { color(0xc8c8c8,0x565656,scheme) }
    public static func controlPressed(_ scheme:ColorScheme) -> Color { color(0xb9b9b9,0x666666,scheme) }
    public static func ink(_ scheme:ColorScheme) -> Color { color(0x0d0d0d,0xffffff,scheme) } // gray-1000
    public static func headerAccent(_ scheme:ColorScheme) -> Color { color(0xd21c25,0xff4038,scheme) }
    public static func muted(_ scheme:ColorScheme) -> Color { color(0x414141,0xdcdcdc,scheme) } // gray-600 / gray-850
    public static func project(_ scheme:ColorScheme) -> Color { color(0x4f4f4f,0xcdcdcd,scheme) } // gray-550 / gray-800
    public static func sourceBadge(_ scheme:ColorScheme) -> Color { color(0xececec,0x444444,scheme) }
    public static func tokenTotal(_ scheme:ColorScheme) -> Color { color(0x5d5d5d,0xb9b9b9,scheme) }
    public static func divider(_ scheme:ColorScheme) -> Color {
        color(0x000000,0xffffff,scheme).opacity(scheme == .dark ? 0.12 : 0.10)
    }

    public static func statusStripe(_ group: ActivityGroup, _ scheme: ColorScheme, pulsing: Bool = false) -> Color {
        let opacity: Double
        switch group {
        case .attention: opacity = pulsing ? 1 : 0.76
        case .working: opacity = 0.66
        case .ready: opacity = 0.54
        case .other: opacity = 0.45
        }
        return statusAccent(group,scheme).opacity(opacity)
    }

    private static func statusAccent(_ group: ActivityGroup, _ scheme: ColorScheme) -> Color {
        switch group {
        case .attention: return color(0x923b0f,0xff9e6c,scheme)
        case .working: return color(0x0169cc,0x66b5ff,scheme)
        case .ready: return color(0x00692a,0x66d492,scheme)
        case .other: return muted(scheme)
        }
    }

    // Status labels use higher-contrast shades of the same SDK hues.
    public static func statusText(_ state:ActivityState,_ scheme:ColorScheme) -> Color {
        switch state {
        case .needsInput: return color(0x6d2e0f,0xffe7d9,scheme) // orange-800 / orange-50
        case .running: return color(0x004f99,0xcce6ff,scheme) // blue-600 / blue-75
        case .completed: return color(0x004f1f,0xb8ebcc,scheme) // green-800 / green-75
        case .failed: return color(0x6e1615,0xffd9d9,scheme) // red-800 / red-50
        default: return muted(scheme)
        }
    }
}

public let metadataIconGap: CGFloat = 4

public struct HoverArea: NSViewRepresentable {
    let changed: (Bool) -> Void

    public init(changed: @escaping (Bool) -> Void) { self.changed = changed }

    public final class TrackingView: NSView {
        var changed: ((Bool) -> Void)?

        public override func hitTest(_ point: NSPoint) -> NSView? { nil }
        public override func mouseEntered(with event: NSEvent) { changed?(true) }
        public override func mouseExited(with event: NSEvent) { changed?(false) }
    }

    public func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.addTrackingArea(NSTrackingArea(rect:.zero,
            options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:view,userInfo:nil))
        return view
    }

    public func updateNSView(_ view: TrackingView, context: Context) {
        view.changed = changed
    }
}

public struct HoverFill: View {
    let active: Bool
    let pressed: Bool

    public init(active: Bool, pressed: Bool = false) {
        self.active = active
        self.pressed = pressed
    }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        RoundedRectangle(cornerRadius:5,style:.continuous)
            .fill(pressed ? PanelPalette.controlPressed(scheme) : PanelPalette.controlHover(scheme))
            .opacity(active ? 1 : 0)
            .animation(PanelMotion.feedback.animation(reduceMotion:reduceMotion),value:active)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
