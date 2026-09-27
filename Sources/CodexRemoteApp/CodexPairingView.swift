import SwiftUI
import AppKit
import CodexRemoteKit

/// Window content: the pairing flow for whichever machine was picked, or an explanation if
/// the window is opened with nothing selected (which can happen after a restart).
struct CodexPairingHost: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let machine = state.codexPairingTarget {
                CodexPairingView(machine: machine)
            } else {
                VStack(spacing: Theme.Space.normal) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("Pick a machine to pair")
                        .font(.headline)
                    Text("Open Codex Remote from the menu bar and choose Pair with Codex on the machine you want.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(28)
                .frame(width: 460, height: 320)
            }
        }
    }
}

/// Shows the machine's pairing code and walks the user to the one place it goes.
///
/// Codex Remote could POST the code to `/wham/remote/control/client/pair` itself — it holds the
/// account token — and deliberately does not. A paired device can execute code under the
/// user's account, and the client checks an MFA requirement before pairing for exactly
/// that reason. So the job here is to make the manual step short and unambiguous: mint the
/// code, show it big, put it on the clipboard, and open the Codex app at the right pane.
struct CodexPairingView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let machine: Machine

    @State private var phase: Phase = .starting
    @State private var code: CodexRemoteControl.PairingCode?
    @State private var errorText: String?
    @State private var copied = false
    @State private var now = Date()
    @State private var closingIn = 10

    private enum Phase { case starting, ready, refreshing, paired }

    /// Drives the countdown. The code expires in minutes, and a code that has quietly gone
    /// stale looks exactly like one Codex rejected — so the clock is on screen.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            header

            switch phase {
            case .starting:
                HStack(spacing: Theme.Space.snug) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text("Turning on remote control on \(machine.name)…")
                            .font(.callout)
                        Text("First time on a machine this installs the daemon, so give it a moment.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

            case .ready, .refreshing:
                if let code { codeBlock(code) }

            case .paired:
                paired
            }

            if let errorText {
                Label {
                    Text(errorText)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(Theme.Space.gutter + Theme.Space.tight)
        .frame(width: 460, height: 340)
        .task { await begin() }
        .task { await watchForPairing() }
        .onReceive(clock) { now = $0 }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("Pair \(machine.name) with Codex")
                .font(.title3.weight(.semibold))
            Text("The machine connects to Codex itself, so you can reach it from here or from your phone — no SSH, no ports.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeBlock(_ code: CodexRemoteControl.PairingCode) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.normal) {
            HStack(spacing: Theme.Space.snug) {
                ForEach(Array(code.displayGroups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Text("–")
                            .font(.system(size: 22, weight: .light, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text(group)
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .tracking(3)
                        .padding(.vertical, Theme.Space.snug)
                        .padding(.horizontal, Theme.Space.normal)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .fill(.quaternary.opacity(0.5))
                        )
                }

                Spacer()

                Button {
                    copy(code.manualCode)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy the pairing code")
                .disabled(phase == .refreshing)
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pairing code")
            // Spelled out, because a screen reader running the groups together would be
            // unusable for something that has to be typed exactly.
            .accessibilityValue(code.manualCode.map { char in
                char == "-" ? "dash" : String(char)
            }.joined(separator: " "))

            expiry(code)

            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text("In Codex: **Settings → Connections → Control other devices → Add**, then paste it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    copy(code.manualCode)
                    NSWorkspace.shared.open(CodexRemoteControl.connectionsDeepLink)
                } label: {
                    Label("Copy code and open Codex", systemImage: "arrow.up.forward.app")
                }
                .controlSize(.large)
                .disabled(phase == .refreshing || code.hasExpired)
                .help("Copies the code and opens the Codex app at Connections")
            }
        }
    }

    /// Confirmation rather than a window that just vanishes: pairing happens over in
    /// another app, so the answer to "did that work?" has to be here when they come back.
    private var paired: some View {
        VStack(alignment: .leading, spacing: Theme.Space.normal) {
            Label {
                Text("\(machine.name) is paired.")
                    .font(.callout.weight(.medium))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)

            Text("It is in Codex under Connections, and you can reach it from this Mac or your phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Closing in \(closingIn)s")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .accessibilityLabel("This window closes in \(closingIn) seconds")
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func expiry(_ code: CodexRemoteControl.PairingCode) -> some View {
        if code.hasExpired {
            Label("This code has expired — get a new one.", systemImage: "clock.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let expiresAt = code.expiresAt {
            let remaining = Int(expiresAt.timeIntervalSince(now).rounded(.down))
            Label("Expires in \(remaining / 60)m \(remaining % 60)s",
                  systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var footer: some View {
        HStack {
            if phase == .paired {
                Spacer()
                Button("Close now") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
            if phase != .starting {
                Button {
                    Task { await refresh() }
                } label: {
                    if phase == .refreshing {
                        HStack(spacing: Theme.Space.tight) {
                            ProgressView().controlSize(.small)
                            Text("New code")
                        }
                    } else {
                        Label("New code", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(phase == .refreshing)
                .help("Codes are short-lived; this mints another")
            }
            Spacer()
            Button("Done") { finish() }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finish() {
        state.codexPairingTarget = nil
        dismiss()
    }

    // MARK: - Actions

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation { copied = false }
        }
    }

    private func begin() async {
        guard phase == .starting else { return }
        do {
            let minted = try await state.beginCodexPairing(machine)
            code = minted
            // Already known to Codex — showing a code to type would be asking for work
            // that has no effect. Confirm and get out of the way instead.
            phase = CodexRemoteControl.isPaired(environmentID: minted.environmentID) ? .paired : .ready
        } catch {
            errorText = error.localizedDescription
            phase = .ready
        }
    }

    /// Polls the Codex app's own state for this machine's device id. Codex gives no
    /// callback, and the user is in another app while it happens, so noticing is on us.
    private func watchForPairing() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if phase != .paired {
                guard phase == .ready || phase == .refreshing else { continue }
                guard CodexRemoteControl.isPaired(environmentID: code?.environmentID) else { continue }
                withAnimation { phase = .paired }
            }
            // Counted down visibly rather than closed out from under them: they may still
            // want the machine name, and a window that disappears unprompted reads as a bug.
            while closingIn > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                closingIn -= 1
            }
            if !Task.isCancelled { finish() }
            return
        }
    }

    private func refresh() async {
        phase = .refreshing
        errorText = nil
        do {
            code = try await state.refreshCodexPairing(machine)
        } catch {
            errorText = error.localizedDescription
        }
        phase = .ready
    }
}
