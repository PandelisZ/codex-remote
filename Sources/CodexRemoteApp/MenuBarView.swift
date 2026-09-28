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
    @State private var promptCopied = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.5)

            if state.machines.isEmpty {
                emptyState
            } else {
                ScrollView {
                    machineList
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: machineListLimit)
                .fixedSize(horizontal: false, vertical: true)
                .softScrollEdges()
            }

            if case .available(let release) = state.updateOutcome {
                UpdateNotice(release: release).environmentObject(state)
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

    /// Keep the title and actions in view even when a short list contains expanded rows,
    /// a long error, or an inline removal confirmation.
    private var machineListLimit: CGFloat {
        min(460, max(220, (NSScreen.main?.visibleFrame.height ?? 800) - 280))
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
        VStack(alignment: .leading, spacing: Theme.Space.gutter) {
            HStack(spacing: Theme.Space.normal) {
                if let icon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "server.rack")
                        .font(.system(size: 32))
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text("Set up your first machine")
                        .font(.headline)
                    Text("A cloud server for Codex, Claude Code, or both.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.normal) {
                if state.accounts.isEmpty {
                    setupStep(1, title: "Connect a cloud account",
                              detail: "Add a provider token. It stays in your Mac's keychain.",
                              action: {
                                  NSApp.activate(ignoringOtherApps: true)
                                  openSettings()
                              })
                } else {
                    setupStep(1, title: "Cloud account connected",
                              detail: "Your provider is ready to create a machine.")
                }
                setupStep(2, title: "Create a machine",
                          detail: "Choose a region, size, and agents. Review the price before creating it.")
            }

            Divider()

            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text("Want your agent to walk you through it?")
                    .font(.subheadline.weight(.medium))
                Text("Copy the setup prompt and paste it into Codex or Claude. It will ask one question at a time and show you the command before creating a server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    state.copySetupPrompt()
                } label: {
                    Label(promptCopied ? "Copied — paste into your agent" : "Copy setup prompt",
                          systemImage: promptCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Copy instructions for an agent to help set up a machine")
            }
        }
        .padding(Theme.Space.gutter + Theme.Space.tight)
        .onChange(of: state.setupPromptCopiedAt) { _, _ in
            withAnimation { promptCopied = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                withAnimation { promptCopied = false }
            }
        }
    }

    private func setupStep(_ number: Int, title: String, detail: String,
                           action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.normal) {
            Text("\(number)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button("Connect provider…", action: action)
                        .controlSize(.small)
                        .padding(.top, Theme.Space.snug)
                }
            }
        }
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

    // Not `instanceID != nil`: a provision that failed before the cloud returned an id can
    // still have left a key pair and a security group behind, and those are ours to remove.
    private var canDestroy: Bool { machine.ownsServer }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.normal) {
            Label {
                Text(canDestroy
                     ? "Remove \(machine.name)? This deletes the server too — everything on it goes with it. Keeping it means it carries on billing to your \(machine.spec.providerKind) account."
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
                    // Deleting is the default action, because the alternative leaves a
                    // server running that no longer appears in this list and keeps billing.
                    // Keeping it stays available, but it is the deliberate choice now.
                    Button("Keep the server") { onChoice(false) }
                        .controlSize(.small)
                    Button("Delete server", role: .destructive) { onChoice(true) }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
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


/// A new build is out. Shown in the panel rather than as a notification: it is worth
/// knowing, not worth interrupting anything for.
struct UpdateNotice: View {
    @EnvironmentObject private var state: AppState
    let release: UpdateChecker.Release

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text("Version \(release.version) is available")
                    .font(.caption.weight(.medium))
                if let progress = state.updateProgress {
                    Text(progressLabel(progress))
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let notes = release.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Theme.Space.tight)

            if state.updateProgress != nil {
                ProgressView().controlSize(.small)
            } else {
                Button("Update") { state.installUpdate(release) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Space.roomy)
        .padding(.vertical, Theme.Space.normal)
        .background(Color.accentColor.opacity(0.08))
    }

    private func progressLabel(_ progress: Updater.Progress) -> String {
        switch progress {
        case .downloading: return "Downloading…"
        case .verifying: return "Checking the download…"
        case .installing: return "Installing…"
        case .relaunching: return "Restarting…"
        }
    }
}
