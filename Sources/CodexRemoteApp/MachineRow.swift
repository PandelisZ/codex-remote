import SwiftUI
import CodexRemoteKit

/// One machine in the list.
///
/// This is the **content layer**, so it carries no Liquid Glass — Apple is explicit that
/// glass belongs to the controls floating above content, not to the content itself. The
/// single exception is the primary "Open" action, which is the most important functional
/// element in the app and the one place a glass control earns its keep.
struct MachineRow: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    let machine: Machine
    let progress: String?
    let isProvisioning: Bool
    let onDelete: () -> Void

    @State private var isExpanded = false
    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    /// Opens the sign-in as its own window, so going to the browser and back does not
    /// close it.
    private func openSignIn() {
        state.claudeSignInTarget = machine
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: CodexRemoteApp.claudeSignInWindowID)
    }

    /// Same reasoning as the sign-in: the pairing code has to stay on screen while the
    /// user is over in the Codex app pasting it.
    private func openCodexPairing() {
        state.codexPairingTarget = machine
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: CodexRemoteApp.codexPairingWindowID)
    }

    private var needsClaudeSignIn: Bool {
        machine.status(of: .claudeCode)?.needsSignIn == true
    }

    /// Claude is installed but waiting on a browser sign-in; say so where it is noticed
    /// rather than burying it in the actions menu.
    private var claudeSignInPrompt: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "person.badge.key")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Claude Code needs a one-off sign-in on this machine.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.tight)
            Button("Sign in") { openSignIn() }
                .controlSize(.small)
        }
        .padding(.leading, Theme.Space.roomy + 30)
        .padding(.trailing, Theme.Space.roomy)
        .padding(.bottom, Theme.Space.normal)
    }

    private var presentation: MachinePresentation {
        MachinePresentation(machine, isProvisioning: isProvisioning)
    }

    /// Only a machine Codex Remote created at a real provider can be powered off and on.
    private var canPowerCycle: Bool {
        machine.spec.providerKind != .existingHost && machine.instanceID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if needsClaudeSignIn { claudeSignInPrompt }
            if isExpanded { details }
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
                .padding(.horizontal, Theme.Space.snug)
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(machine.name), \(presentation.spokenState)")
    }

    // MARK: - Collapsed

    private var summary: some View {
        HStack(spacing: Theme.Space.normal) {
            StatusIndicator(presentation: presentation, isAnimating: isProvisioning)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                HStack(spacing: Theme.Space.snug) {
                    if isRenaming {
                        TextField("Name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 160)
                            .focused($nameFieldFocused)
                            .onSubmit(commitRename)
                            .onExitCommand { isRenaming = false }
                    } else {
                        Text(machine.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                    }
                    ProviderBadge(kind: machine.spec.providerKind)
                }

                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(machine.stage == .failed ? AnyShapeStyle(Color.red)
                                                              : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Space.tight)

            controls
        }
        .padding(.horizontal, Theme.Space.roomy)
        .padding(.vertical, Theme.Space.normal)
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
        }
    }

    @ViewBuilder
    private var controls: some View {
        // The pause switch is a content-layer control, so it stays a standard Toggle —
        // Apple's note about transient glass applies to the system's own switch rendering,
        // not to something we should paint on.
        if canPowerCycle {
            Toggle("Running", isOn: Binding(
                get: { machine.powerIntent == .up },
                set: { state.setPower(machine, up: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(isProvisioning)
            .help(machine.powerIntent == .up
                  ? "Pause \(machine.name) — powers the server off at \(machine.spec.providerKind)"
                  : "Resume \(machine.name) — powers the server back on")
            .accessibilityLabel("\(machine.name) running")
        }

        if machine.isReady {
            Button("Open") {
                // A Claude-only machine has no launcher to run; its session is the thing
                // to open. Sending it to the Codex path would only ever show an error.
                if machine.runs(.codex) { state.openInCodex(machine) }
                else { state.openInClaude(machine) }
            }
                .buttonStyle(PrimaryGlassButtonStyle())
                .help(machine.runs(.codex) ? "Open a Codex session on \(machine.name)"
                                           : "Open \(machine.name) in Claude")
        }

        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .frame(width: 16)
            .accessibilityHidden(true)
    }

    /// While setting up, the live stage message; otherwise the resting status.
    private var statusLine: String {
        if isProvisioning, let progress { return "\(machine.stage.label) — \(progress)" }
        return machine.statusText
    }

    // MARK: - Expanded

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.normal) {
            if isProvisioning {
                ProgressView(value: machine.stage.progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Setup progress")
            }

            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                detail("Endpoint", machine.endpoint, monospaced: true)
                detail("SSH", "ssh \(machine.sshHostAlias)", monospaced: true)
                if let address = machine.instance?.sshAddress {
                    detail("Address", "\(machine.sshUser)@\(address)", monospaced: true)
                }
                detail("Workspace", machine.spec.workspacePath, monospaced: true)
                if machine.spec.providerKind != .existingHost {
                    detail("Server", "\(machine.spec.size) · \(machine.spec.region)")
                }
                if let version = machine.codexVersion { detail("Remote Codex", version) }
            }

            if let error = machine.lastError, machine.stage == .failed {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions
        }
        .padding(.leading, Theme.Space.roomy + 30)
        .padding(.trailing, Theme.Space.roomy)
        .padding(.bottom, Theme.Space.roomy)
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.snug) {
            if machine.isReady {
                if machine.runs(.codex) {
                    Button {
                        state.openInCodex(machine)
                    } label: {
                        Label("Open in Codex", systemImage: "terminal")
                    }
                    .controlSize(.small)
                }
                if machine.runs(.claudeCode) {
                    Button {
                        state.openInClaude(machine)
                    } label: {
                        Label("Open in Claude", systemImage: "arrow.up.forward.app")
                    }
                    .controlSize(.small)
                    .disabled(machine.claudeSessionURL == nil)
                }
            }

            Menu {
                // Grouped by agent, because a machine can run either or both and the
                // actions are not interchangeable: Codex opens a terminal, Claude opens a
                // session in your account.
                if machine.runs(.codex) {
                    Section("Codex") {
                        Button("Open in Codex") { state.openInCodex(machine) }
                        Button("Copy `codex --remote` command") { state.copyConnectCommand(machine) }
                        Button("Pair with Codex…") { openCodexPairing() }
                    }
                }
                if machine.runs(.claudeCode) {
                    Section("Claude Code") {
                        Button("Open Claude session") { state.openInClaude(machine) }
                            .disabled(machine.claudeSessionURL == nil)
                        Button("Copy session link") { state.copyClaudeSessionURL(machine) }
                            .disabled(machine.claudeSessionURL == nil)
                        Button(needsClaudeSignIn ? "Sign in to Claude…" : "Sign in again…") { openSignIn() }
                    }
                }
                Divider()
                // Both agents already record the projects you work on, so this is a pick
                // rather than a path to remember. Recent first; the submenu is built when
                // the menu opens so it never reads a stale list.
                Menu("Send a project") {
                    let projects = state.discoverProjects()
                    if projects.isEmpty {
                        Text("No projects found in Codex or Claude Code")
                    } else {
                        ForEach(projects) { project in
                            Button {
                                state.sendProject(project, to: machine)
                            } label: {
                                Text("\(project.name)  —  \(project.sourceLabel)")
                            }
                        }
                    }
                }
                Button("Copy `ssh \(machine.sshHostAlias)`") { state.copySSHCommand(machine) }
                Divider()
                Button("Reconnect tunnel") { state.reconnect(machine) }
                Button("Re-run remote setup") { state.repair(machine) }
                Button("Rename…") {
                    draftName = machine.name
                    isRenaming = true
                    nameFieldFocused = true
                }
                Divider()
                Button("Remove…", role: .destructive, action: onDelete)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("More actions for \(machine.name)")

            Spacer()
        }
    }

    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        LabeledContent {
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        } label: {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .labeledContentStyle(DetailLineStyle())
    }

    private func commitRename() {
        isRenaming = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != machine.name else { return }
        state.rename(machine, to: trimmed)
    }
}

/// Label on the left at a fixed width, value on the right — the shape macOS uses for
/// read-only property lists.
private struct DetailLineStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
            configuration.label.frame(width: 84, alignment: .leading)
            configuration.content
            Spacer(minLength: 0)
        }
    }
}

/// Which cloud a machine lives on, as a quiet capsule rather than shouting in the title.
struct ProviderBadge: View {
    let kind: ProviderKind

    var body: some View {
        Text(kind.rawValue)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
            .accessibilityLabel("provider \(kind.rawValue)")
    }
}

/// The app's one prominent action. Liquid Glass on macOS 26, a bordered button below —
/// used here and nowhere else, per Apple's "sparingly" rule.
struct PrimaryGlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, Theme.Space.roomy)
            .padding(.vertical, Theme.Space.snug)
            .opacity(configuration.isPressed ? 0.7 : 1)

        if #available(macOS 26.0, *), !reduceTransparency {
            label.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            label.background(.thinMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.separator))
        }
    }
}
