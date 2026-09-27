import SwiftUI
import CodexRemoteKit

/// The menu bar popover.
///
/// The popover's own background is already a system material, so the machine list sits on
/// it plainly as content. Liquid Glass appears once, on the action bar at the bottom —
/// that bar is the control layer, and keeping glass to a single grouped container is what
/// Apple means by using the effect sparingly.
struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    /// Removal is confirmed inline rather than in an alert: an alert raised from a menu bar
    /// popover disappears with the popover as soon as focus moves.
    @State private var pendingDeletion: Machine?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.5)

            if state.machines.isEmpty {
                emptyState
            } else if state.machines.count > 7 {
                ScrollView { machineList }
                    .frame(height: 460)
                    .softScrollEdges()
            } else {
                machineList
            }

            if let banner = state.banner {
                BannerView(banner: banner) { state.banner = nil }
            }

            Divider().opacity(0.5)

            actionBar
        }
        .frame(width: Theme.popoverWidth)
        .onChange(of: state.machines.count) { pendingDeletion = nil }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.normal) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex Remote")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            IconButton(systemName: "arrow.clockwise",
                       help: "Re-read state from every provider") {
                state.refreshFromProviders()
            }
        }
        .padding(.horizontal, Theme.Space.roomy)
        .padding(.top, Theme.Space.roomy)
        .padding(.bottom, Theme.Space.normal)
    }

    private var summary: String {
        if state.machines.isEmpty { return "No machines yet" }
        var parts = ["\(state.onlineCount) of \(state.machines.count) online"]
        if state.isBusy { parts.append("\(state.provisioningIDs.count) setting up") }
        if state.hasFailures { parts.append("needs attention") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Content

    private var machineList: some View {
        VStack(spacing: 0) {
            ForEach(state.machines) { machine in
                MachineRow(machine: machine,
                           progress: state.lastProgress[machine.id],
                           isProvisioning: state.provisioningIDs.contains(machine.id),
                           onDelete: { withAnimation(.snappy) { pendingDeletion = machine } })

                if pendingDeletion?.id == machine.id {
                    RemovalConfirmation(machine: machine) { destroy in
                        if let destroy { state.remove(machine, destroyInstance: destroy) }
                        withAnimation(.snappy) { pendingDeletion = nil }
                    }
                }

                if machine.id != state.machines.last?.id {
                    Divider()
                        .opacity(0.4)
                        .padding(.leading, Theme.Space.roomy + 30)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.normal) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text("No machines yet")
                .font(.subheadline.weight(.medium))

            Text(state.accounts.isEmpty
                 ? "Add a provider token in Settings, then spin one up. Codex Remote builds the server, installs Codex on it, and adds it to Codex's Remotes."
                 : "Create one and Codex Remote will build the server, install Codex on it, and wire it into Codex.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.accounts.isEmpty {
                Button("Open Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
    }

    // MARK: - Action bar (the control layer)

    private var actionBar: some View {
        HStack(spacing: Theme.Space.tight) {
            Button {
                open(CodexRemoteApp.newMachineWindowID)
            } label: {
                Label("New machine", systemImage: "plus")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, Theme.Space.normal)
                    .padding(.vertical, Theme.Space.snug)
            }
            .buttonStyle(.plain)
            .glassSurface(.capsule, interactive: true)
            .disabled(state.accounts.isEmpty)
            .help(state.accounts.isEmpty
                  ? "Add a provider account first"
                  : "Build a new remote Codex machine")

            Spacer()

            IconButton(systemName: "list.bullet.rectangle", help: "Activity") {
                open(CodexRemoteApp.activityWindowID)
            }
            IconButton(systemName: "gearshape", help: "Settings") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            IconButton(systemName: "power", help: "Quit Codex Remote, closing all tunnels") {
                state.quit()
            }
        }
        .padding(.horizontal, Theme.Space.roomy)
        .padding(.vertical, Theme.Space.normal)
        .glassGroup(spacing: Theme.Space.normal)
    }

    /// Opening a window has to bring the app forward too, or it appears behind whatever
    /// the user was in when they clicked the menu bar.
    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}

/// Inline "are you sure" strip. `onChoice(nil)` cancels; `onChoice(true)` also destroys the
/// server at the provider.
struct RemovalConfirmation: View {
    let machine: Machine
    let onChoice: (Bool?) -> Void

    private var canDestroy: Bool {
        machine.spec.providerKind != .existingHost && machine.instanceID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.normal) {
            Label {
                Text(canDestroy
                     ? "Remove \(machine.name)? Deleting the server is permanent — everything on it goes with it."
                     : "Stop managing \(machine.name)? Codex Remote takes its Codex service off the machine and leaves the machine alone.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            HStack(spacing: Theme.Space.snug) {
                Button("Cancel") { onChoice(nil) }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if canDestroy {
                    Button("Just remove") { onChoice(false) }
                        .controlSize(.small)
                    Button("Delete server", role: .destructive) { onChoice(true) }
                        .controlSize(.small)
                } else {
                    Button("Remove", role: .destructive) { onChoice(false) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, Theme.Space.roomy)
        .padding(.vertical, Theme.Space.normal)
        .background(Color.red.opacity(0.08))
    }
}

struct BannerView: View {
    let banner: AppState.Banner
    let dismiss: () -> Void

    private var tint: Color {
        switch banner.kind {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var symbol: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.normal) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(banner.message)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Theme.Space.tight)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, Theme.Space.roomy)
        .padding(.vertical, Theme.Space.normal)
        .background(tint.opacity(0.08))
    }
}
