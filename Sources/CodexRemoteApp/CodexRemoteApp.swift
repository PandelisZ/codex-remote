import SwiftUI
import CodexRemoteKit

@main
struct CodexRemoteApp: App {
    static let panelWindowID = "codex-remote-panel"
    static let newMachineWindowID = "codex-remote-new-machine"
    static let activityWindowID = "codex-remote-activity"
    static let claudeSignInWindowID = "codex-remote-claude-signin"
    static let codexPairingWindowID = "codex-remote-codex-pairing"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            // The menu bar is the system's own control layer: it supplies the material, so
            // the item is just a symbol. It still carries state — a count when machines are
            // online, a different glyph while setting up or when something failed — so the
            // status is readable without opening anything, and not by colour alone.
            MenuBarLabel(symbol: state.menuBarSymbol,
                         count: state.onlineCount,
                         spoken: state.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)

        // The same panel as a real window. A menu bar item can be hidden by the user's
        // menu bar manager (Bartender, Ice, a notch), which leaves the app unreachable —
        // and an accessory app has no window for UI automation or a screen recorder to
        // attach to. `CODEX_REMOTE_SHOW_IN_DOCK=1` opens this window at launch.
        Window("Codex Remote", id: CodexRemoteApp.panelWindowID) {
            MenuBarView()
                .environmentObject(state)
                .frame(width: Theme.popoverWidth)
                .fixedSize(horizontal: true, vertical: false)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Open Codex Remote Window") { openPanelWindow() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
        }

        // Auxiliary panels are windows, not sheets. A menu bar popover is dismissed the
        // moment focus leaves it, which takes any sheet down with it, so anything the user
        // has to type into has to live in a window of its own.
        Window("New machine", id: CodexRemoteApp.newMachineWindowID) {
            NewMachineSheet().environmentObject(state)
        }
        .windowResizability(.contentSize)

        Window("Codex Remote Activity", id: CodexRemoteApp.activityWindowID) {
            ActivityView().environmentObject(state)
        }
        .windowResizability(.contentSize)

        // Both of these are real windows, not sheets on the popover. Each one sends you to
        // another app and expects you back with a code — and a menu bar popover closes the
        // instant focus leaves it, taking any sheet with it. The Claude code field was
        // unusable for exactly that reason: clicking into it dismissed the whole thing.
        // The pairing window is worse if it gets this wrong, since the code is *on* it.
        Window("Pair with Codex", id: CodexRemoteApp.codexPairingWindowID) {
            CodexPairingHost().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Sign in to Claude", id: CodexRemoteApp.claudeSignInWindowID) {
            ClaudeSignInHost().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

/// Holds SwiftUI's `openWindow` action so code outside the view tree — the menu command,
/// the app delegate — can open the panel window.
///
/// A `Window` scene has no `NSWindow` until something opens it, so looking through
/// `NSApp.windows` for it finds nothing on a fresh launch, and only SwiftUI's own action
/// can bring it into being. This used to fall back to opening a `codex-remote://` URL, a
/// scheme the bundle never registered, so the menu item quietly did nothing at all.
@MainActor
final class PanelWindow {
    static let shared = PanelWindow()
    var open: (() -> Void)?
}

/// Opens (or re-focuses) the standalone panel window.
@MainActor
func openPanelWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let existing = NSApp.windows.first(where: { $0.title == "Codex Remote" }) {
        existing.makeKeyAndOrderFront(nil)
        return
    }
    PanelWindow.shared.open?()
}

/// Lends the menu bar label its environment, which is the only place in an accessory app
/// guaranteed to be instantiated at launch.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    let symbol: String
    let count: Int
    let spoken: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(spoken)
        .task { PanelWindow.shared.open = { openWindow(id: CodexRemoteApp.panelWindowID) } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no main window. CODEX_REMOTE_SHOW_IN_DOCK=1 flips it to a
        // regular app, which is how UI automation and screen recorders can see it at all —
        // an accessory app is invisible to most window enumerations.
        let showInDock = ProcessInfo.processInfo.environment["CODEX_REMOTE_SHOW_IN_DOCK"] == "1"
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        Log.shared.info("app", "Codex Remote started.")
        if showInDock {
            // Give the scene graph a moment to register the window before asking for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                openPanelWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TunnelManager.shared.stopAll()
        Log.shared.info("app", "Codex Remote stopped; all tunnels closed.")
    }
}
