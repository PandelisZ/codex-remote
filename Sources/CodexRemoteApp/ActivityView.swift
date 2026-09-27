import SwiftUI
import CodexRemoteKit

/// Live log pane. Provisioning is slow and happens over SSH, so when something goes wrong
/// the user needs to see what the remote actually said, not just "failed".
struct ActivityView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var minimumLevel: LogLevel = .info

    private var lines: [LogLine] {
        let order: [LogLevel: Int] = [.debug: 0, .info: 1, .warn: 2, .error: 3]
        return state.activity.filter { line in
            (order[line.level] ?? 0) >= (order[minimumLevel] ?? 0)
                && (filter.isEmpty
                    || line.message.localizedCaseInsensitiveContains(filter)
                    || line.scope.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.normal) {
                            Text(line.scope)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 76, alignment: .leading)
                            Text(line.message)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line.level))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .id(line.id)
                        .padding(.horizontal, Theme.Space.gutter)
                    }
                }
                .padding(.vertical, Theme.Space.normal)
            }
            .softScrollEdges()
            .onChange(of: lines.count) {
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(minWidth: 680, idealWidth: 740, minHeight: 420, idealHeight: 480)
        // A toolbar is the app's navigation layer, and the system gives it Liquid Glass on
        // macOS 26 — which is exactly where Apple wants the effect, so the filters live
        // here rather than in a hand-rolled header bar.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Level", selection: $minimumLevel) {
                    Text("All").tag(LogLevel.debug)
                    Text("Info").tag(LogLevel.info)
                    Text("Warnings").tag(LogLevel.warn)
                    Text("Errors").tag(LogLevel.error)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .help("Show only messages at this level or above")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.revealLogs()
                } label: {
                    Label("Reveal log file", systemImage: "folder")
                }
                .help("Show codex-remote.log in the Finder")
            }
        }
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter activity")
        .navigationTitle("Activity")
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
