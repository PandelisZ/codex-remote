import SwiftUI
import CodexRemoteKit

/// The one-off browser sign-in a machine needs before Claude Code can join your account.
///
/// Codex Remote does not copy this Mac's Claude login to the machine. It authenticates for
/// inference, but refreshing it consumes a single-use refresh token, so the two installs
/// invalidate each other and Remote Control drops. The machine signs in for itself instead
/// and keeps its own credential.
/// Window content: shows the sign-in for whichever machine was picked, or an explanation
/// if the window is opened with nothing selected (which can happen after a restart).
struct ClaudeSignInHost: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let machine = state.claudeSignInTarget {
                ClaudeSignInView(machine: machine)
            } else {
                VStack(spacing: Theme.Space.normal) {
                    Image(systemName: "person.badge.key")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("Pick a machine to sign in")
                        .font(.headline)
                    Text("Open Codex Remote from the menu bar and choose Sign in on the machine you want.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(28)
                .frame(width: 460, height: 300)
            }
        }
    }
}

struct ClaudeSignInView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let machine: Machine

    @State private var pending: ClaudeLogin.Pending?
    @State private var code = ""
    @State private var phase: Phase = .starting
    @State private var errorText: String?
    @FocusState private var codeFieldFocused: Bool

    private enum Phase { case starting, waitingForCode, submitting, done }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.roomy) {
            header

            switch phase {
            case .starting:
                HStack(spacing: Theme.Space.snug) {
                    ProgressView().controlSize(.small)
                    Text("Starting sign-in on \(machine.name)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

            case .waitingForCode, .submitting:
                codeEntry

            case .done:
                Label("\(machine.name) is signed in. Bringing Remote Control up…",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .transition(.opacity)
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

            HStack {
                Spacer()
                Button(phase == .done ? "Done" : "Cancel") {
                    state.claudeSignInTarget = nil
                    dismiss()
                }
                    .keyboardShortcut(phase == .done ? .defaultAction : .cancelAction)
                if phase == .waitingForCode {
                    Button("Sign in") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(Theme.Space.gutter + Theme.Space.tight)
        .frame(width: 460, height: 300)
        .task { await begin() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("Sign \(machine.name) in to Claude Code")
                .font(.title3.weight(.semibold))
            Text("The machine gets its own login, so it never shares this Mac's — two installs cannot use one credential.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: Theme.Space.normal) {
            Text("Approve the sign-in in your browser, then paste the code it gives you.")
                .font(.callout)

            HStack(spacing: Theme.Space.snug) {
                TextField("Code from the browser", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .focused($codeFieldFocused)
                    .onSubmit(submit)
                    .disabled(phase == .submitting)
                    .accessibilityLabel("Sign-in code")

                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        code = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .labelStyle(.iconOnly)
                }
                .help("Paste the code from the clipboard")
                .accessibilityLabel("Paste the code")
                .disabled(phase == .submitting)
                if phase == .submitting {
                    ProgressView().controlSize(.small)
                }
            }

            if let pending {
                Button {
                    NSWorkspace.shared.open(pending.authorizeURL)
                } label: {
                    Label("Open the sign-in page again", systemImage: "safari")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private func begin() async {
        do {
            let started = try await state.beginClaudeSignIn(machine)
            pending = started
            phase = .waitingForCode
            NSWorkspace.shared.open(started.authorizeURL)
            // Focus the field so returning from the browser and pressing ⌘V just works.
            codeFieldFocused = true
        } catch {
            errorText = error.localizedDescription
            phase = .waitingForCode
        }
    }

    private func submit() {
        codeFieldFocused = false
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        phase = .submitting
        errorText = nil
        Task {
            do {
                try await state.completeClaudeSignIn(machine, code: trimmed)
                withAnimation { phase = .done }

                // Show the confirmation long enough to read, then close. Clearing the
                // selection without closing left the window showing "Pick a machine",
                // which reads like the sign-in failed.
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                state.claudeSignInTarget = nil
                dismiss()
            } catch {
                errorText = error.localizedDescription
                phase = .waitingForCode
            }
        }
    }
}
