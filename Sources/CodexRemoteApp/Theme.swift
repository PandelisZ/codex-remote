import SwiftUI
import CodexRemoteKit

/// Design tokens and the app's Liquid Glass policy.
///
/// Apple's guidance is specific and worth restating, because it is easy to get wrong:
/// Liquid Glass "forms a distinct functional layer for controls and navigation elements …
/// that floats above the content layer". It explicitly says **don't** use it in the content
/// layer, and to "use Liquid Glass effects sparingly … Limit these effects to the most
/// important functional elements in your app."
///
/// So in Codex Remote, glass is used in exactly three places — the popover's action bar, the
/// primary "Open" action on a machine, and the menu bar status pill. The machine list, the
/// forms and the activity log are content and stay on standard materials.
enum Theme {
    static let popoverWidth: CGFloat = 384

    /// Corner radii, kept concentric: a control nested inside a container uses the
    /// container's radius minus its inset, so the curves stay parallel.
    enum Radius {
        static let container: CGFloat = 16
        static let row: CGFloat = 10
        static let control: CGFloat = 8
    }

    /// macOS spacing steps. Sticking to these keeps optical rhythm consistent.
    enum Space {
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 6
        static let normal: CGFloat = 10
        static let roomy: CGFloat = 14
        static let gutter: CGFloat = 16
    }

    /// The smallest comfortable pointer target on macOS.
    static let minimumHitTarget: CGFloat = 28
}

// MARK: - Glass

/// Applies Liquid Glass where the platform supports it, and a standard material where it
/// does not — or where the user has asked for less transparency.
///
/// Reduce Transparency and Increase Contrast both change how glass renders, and Apple
/// notes its appearance "can differ in response to certain system settings". Honouring
/// them by dropping to an opaque fill is the safest reading of that for a custom control.
private struct GlassSurface<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            AnyView(content.background(.regularMaterial, in: shape))
        } else if #available(macOS 26.0, *) {
            AnyView(content.glassEffect(glass(), in: shape))
        } else {
            AnyView(content.background(.thinMaterial, in: shape))
        }
    }

    @available(macOS 26.0, *)
    private func glass() -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    /// Liquid Glass for a control-layer surface. Use sparingly — see `Theme`.
    func glassSurface(_ shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
    }

    /// Groups several glass surfaces so they blend and morph as one, which Apple recommends
    /// both for appearance and for rendering cost.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = Theme.Space.snug) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Blurs content as it passes under a toolbar instead of letting it collide with it.
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

// MARK: - Status

/// How a machine's state is shown.
///
/// Colour alone is not enough — it fails for anyone who cannot distinguish the hues, and
/// Apple's accessibility guidance is explicit that colour must not be the only carrier of
/// meaning. Every state therefore has a distinct SF Symbol as well as a colour, and a
/// spoken description for VoiceOver.
struct MachinePresentation {
    let symbol: String
    let tint: Color
    let spokenState: String

    init(_ machine: Machine, isProvisioning: Bool) {
        if machine.stage == .failed {
            symbol = "exclamationmark.triangle.fill"
            tint = .red
            spokenState = "needs attention"
        } else if isProvisioning || machine.stage != .ready {
            symbol = "arrow.triangle.2.circlepath"
            tint = .accentColor
            spokenState = "setting up"
        } else {
            switch machine.health {
            case .online:
                symbol = "checkmark.circle.fill"
                tint = .green
                spokenState = "online"
            case .degraded:
                symbol = "exclamationmark.circle.fill"
                tint = .orange
                spokenState = "not responding"
            case .offline:
                symbol = machine.powerIntent == .down ? "pause.circle.fill" : "moon.circle.fill"
                tint = .secondary
                spokenState = machine.powerIntent == .down ? "paused" : "offline"
            case .unknown:
                symbol = "questionmark.circle.fill"
                tint = .secondary
                spokenState = "checking"
            }
        }
    }
}

/// The status indicator: a symbol carrying the meaning, a colour reinforcing it.
struct StatusIndicator: View {
    let presentation: MachinePresentation
    var isAnimating = false
    @State private var spin = false

    var body: some View {
        Image(systemName: presentation.symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(presentation.tint)
            .symbolRenderingMode(.hierarchical)
            .rotationEffect(.degrees(isAnimating && spin ? 360 : 0))
            .animation(isAnimating ? .linear(duration: 1.8).repeatForever(autoreverses: false) : .default,
                       value: spin)
            .onAppear { if isAnimating { spin = true } }
            .accessibilityHidden(true)
    }
}

/// An icon-only control. Icon-only means it needs a name for VoiceOver and a tooltip for
/// everyone else, and a target big enough to hit.
struct IconButton: View {
    let systemName: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .frame(width: Theme.minimumHitTarget, height: Theme.minimumHitTarget)
                .contentShape(.rect(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
