import Foundation

/// Builds the shell that turns a stock Debian/Ubuntu server into a Codex worker.
///
/// It is deliberately provider-agnostic: nothing here knows about Hetzner, EC2 or
/// DigitalOcean. Everything it needs arrives as parameters, so any provider that can
/// hand back an IP and an SSH key lands on the same machine image.
public struct BootstrapPlan: Sendable {
    public let workspacePath: String
    public let remotePort: Int
    public let tokenPath: String
    public let codexVersion: String?
    public let extraPackages: [String]
    public let postSetupScript: String?
    public let idleShutdownMinutes: Int
    public let serviceUser: String
    /// The unprivileged account Claude Code runs under.
    public let claudeUser: String
    /// What the machine calls itself. This is the name the user typed, so the shell prompt,
    /// the agents and the provider console all agree.
    public let hostname: String

    public init(workspacePath: String = MachineSpec.defaultWorkspacePath,
                remotePort: Int, tokenPath: String = "/etc/codex-remote/appserver.token",
                codexVersion: String? = nil, extraPackages: [String] = [],
                postSetupScript: String? = nil, idleShutdownMinutes: Int = 0,
                serviceUser: String = "root", hostname: String = "codex-remote",
                claudeUser: String = BootstrapScript.claudeUser) {
        self.workspacePath = workspacePath
        self.remotePort = remotePort
        self.tokenPath = tokenPath
        self.codexVersion = codexVersion
        self.extraPackages = extraPackages
        self.postSetupScript = postSetupScript
        self.idleShutdownMinutes = idleShutdownMinutes
        self.serviceUser = serviceUser
        self.hostname = hostname
        self.claudeUser = claudeUser
    }

    public var claudeHome: String { "/home/\(claudeUser)" }

    /// Where the Claude service works.
    ///
    /// It cannot be the shared workspace when that sits under `/root`: `/root` is mode 700,
    /// so an unprivileged account cannot even traverse into it. Machines created before
    /// this change have exactly that, so they get a workspace under the Claude account's
    /// own home instead of silently failing to start.
    public var claudeWorkspace: String {
        workspacePath.hasPrefix("/root") ? "\(claudeHome)/workspace" : workspacePath
    }
}

public enum BootstrapScript {
    /// A hostname is put straight into a shell command, so it is restricted to what a
    /// hostname may legally contain and quoted regardless.
    static func shellSafe(_ value: String) -> String {
        let cleaned = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }
        let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "'" + (trimmed.isEmpty ? "codex-remote" : String(trimmed.prefix(63))) + "'"
    }

    public static let serviceName = "codex-remote-app-server"
    public static let claudeServiceName = "codex-remote-claude"
    public static let remoteControlServiceName = "codex-remote-control"
    /// Claude Code refuses its most permissive mode when running as root, and an agent with
    /// a whole machine to itself has no reason to be root anyway. It gets its own account.
    public static let claudeUser = "claude"
    public static let stateDir = "/etc/codex-remote"

    /// cloud-init handed to providers that accept it. It does nothing Codex Remote depends on —
    /// the SSH bootstrap is the source of truth — it just gets the box updating in the
    /// background so the apt step later is quicker.
    public static func cloudInit() -> String {
        """
        #cloud-config
        package_update: true
        packages:
          - curl
          - ca-certificates
        """
    }

    /// Stage 1: base OS packages. Split from the Codex install so the UI can show progress
    /// and so a failure points at the step that actually broke.
    public static func basePackages(_ plan: BootstrapPlan) -> String {
        return """
        \(preamble)

        # Ubuntu's stock cloud image runs unattended-upgrades on first boot. Left alone it
        # fights every apt call below for the dpkg lock and can restart sshd mid-install,
        # which cuts the very connection running this script. Stand it down for the
        # duration and let the machine's own timer pick it up again afterwards.
        say "Standing down unattended upgrades for the install"
        systemctl stop unattended-upgrades.service >/dev/null 2>&1 || true
        systemctl stop apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true
        systemctl kill --kill-who=all apt-daily.service >/dev/null 2>&1 || true

        # needrestart otherwise opens a curses prompt on a non-interactive apt run and
        # decides on its own to restart sshd.
        mkdir -p /etc/needrestart/conf.d
        cat > /etc/needrestart/conf.d/99-codex-remote.conf <<'CODEX_REMOTE_NEEDRESTART_EOF'
        # Managed by Codex Remote: never prompt, and never bounce sshd from under us.
        $nrconf{restart} = 'a';
        $nrconf{kernelhints} = 0;
        $nrconf{override_rc} = { qr(^ssh(d)?[.]service$) => 0 };
        CODEX_REMOTE_NEEDRESTART_EOF
        sed -i 's/^        //' /etc/needrestart/conf.d/99-codex-remote.conf

        say "Waiting for cloud-init and any running package manager to finish"
        if command -v cloud-init >/dev/null 2>&1; then
          cloud-init status --wait >/dev/null 2>&1 || true
        fi
        wait_for_apt

        say "Installing base packages"
        export DEBIAN_FRONTEND=noninteractive
        $APT update -qq
        $APT install -y -qq --no-install-recommends \\
          ca-certificates curl git ripgrep jq tmux rsync unzip build-essential python3 iproute2 psmisc bubblewrap

        # The machine answers to the name the user gave it — in its own shell prompt, in
        # `who`, and in anything the agents report about where they are running.
        say "Setting the hostname to \(plan.hostname)"
        hostnamectl set-hostname \(shellSafe(plan.hostname)) 2>/dev/null || true
        if ! grep -q "\(shellSafe(plan.hostname))" /etc/hosts 2>/dev/null; then
          printf '127.0.1.1\t%s\n' \(shellSafe(plan.hostname)) >> /etc/hosts
        fi

        say "Creating workspace at \(plan.workspacePath)"
        mkdir -p '\(plan.workspacePath)'
        mkdir -p '\(stateDir)'
        chmod 700 '\(stateDir)'

        say "Restoring unattended upgrades"
        systemctl start unattended-upgrades.service >/dev/null 2>&1 || true

        say "Base packages done"
        """
    }

    /// Stage 2: the Codex CLI.
    ///
    /// Installed from OpenAI's own standalone installer, which fetches a prebuilt binary and
    /// checks it against a published SHA-256. This used to go through npm, which meant
    /// installing Node first, and Node was by far the slowest thing in the whole provision:
    /// measured on a stock Ubuntu 26.04 EC2 instance, `apt install nodejs npm` took 87s and
    /// the npm install 10s, against 5-8s for the standalone binary. Adding NodeSource's repo,
    /// which the old script did on every machine, cost more still.
    ///
    /// `CODEX_HOME` here only decides where the installer unpacks the package. It is set to a
    /// shared path rather than left at the service user's home, because the default puts the
    /// binary under /root/.codex, and /root is mode 700 — unreadable to a service running as
    /// anyone else. Codex's *config* home is untouched and stays per-user.
    public static func installCodex(_ plan: BootstrapPlan) -> String {
        let release = plan.codexVersion.map { "CODEX_RELEASE='\($0)'" } ?? ""
        return """
        \(preamble)

        say "Installing the Codex CLI"
        export CODEX_NON_INTERACTIVE=1
        export CODEX_INSTALL_DIR=/usr/local/bin
        export CODEX_HOME=/opt/codex
        \(release)
        mkdir -p /opt/codex
        curl -fsSL https://chatgpt.com/codex/install.sh | sh >/dev/null

        # The installer unpacks as root; the agent may not run as root.
        chmod -R a+rX /opt/codex

        [ -x /usr/local/bin/codex ] || die "the Codex installer did not leave a binary at /usr/local/bin/codex"
        echo "CODEX_BIN=/usr/local/bin/codex"
        echo "CODEX_VERSION=$(/usr/local/bin/codex --version 2>/dev/null | head -1)"
        say "Codex installed"
        """
    }

    /// Node, installed only when something on the machine actually needs it.
    ///
    /// Nothing does by default any more: Codex is a standalone binary and Claude Code brings
    /// its own runtime. But `MCPSync` calls a server portable when it launches through `npx`,
    /// `npm` or `node`, on the grounds that the bootstrap installs them — so when such a
    /// server is being carried over, that promise has to be kept.
    ///
    /// Ubuntu 26.04 ships Node 22, so the distro package is preferred. NodeSource is the
    /// fallback for older images (24.04 ships Node 18), and costs an extra repo and an
    /// `apt-get update` against it.
    public static func installNode(minimumMajor: Int = 20) -> String {
        """
        \(preamble)

        if command -v node >/dev/null 2>&1; then
          major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
          if [ "$major" -ge \(minimumMajor) ]; then
            say "Node.js $(node -v) already present"
            exit 0
          fi
        fi

        wait_for_apt
        export DEBIAN_FRONTEND=noninteractive
        candidate="$(apt-cache policy nodejs 2>/dev/null | awk '/Candidate:/{print $2}')"
        candidate_major="${candidate%%.*}"
        case "$candidate_major" in ''|*[!0-9]*) candidate_major=0 ;; esac

        if [ "$candidate_major" -ge \(minimumMajor) ]; then
          say "Installing Node.js $candidate_major from Ubuntu"
          $APT install -y -qq nodejs npm
        else
          say "Installing Node.js 22 from NodeSource"
          curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
          $APT install -y -qq nodejs
        fi
        say "Node.js $(node -v) ready"
        """
    }

    /// Stage 3: the systemd unit that keeps `codex app-server` listening on loopback.
    ///
    /// The listener is loopback-only by Codex's own design, so the only route in is the
    /// SSH forward Codex Remote holds open. The bearer token adds a second lock, so another
    /// local account on the box cannot drive the agent.
    public static func installService(_ plan: BootstrapPlan) -> String {
        let unit = """
        [Unit]
        Description=Codex Remote — Codex app-server
        Documentation=https://developers.openai.com/codex
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        User=\(plan.serviceUser)
        Environment=HOME=/\(plan.serviceUser == "root" ? "root" : "home/\(plan.serviceUser)")
        Environment=CODEX_HOME=/\(plan.serviceUser == "root" ? "root" : "home/\(plan.serviceUser)")/.codex
        Environment=NODE_NO_WARNINGS=1
        WorkingDirectory=\(plan.workspacePath)
        ExecStart=/usr/local/bin/codex app-server \\
          --listen ws://127.0.0.1:\(plan.remotePort) \\
          --ws-auth capability-token \\
          --ws-token-file \(plan.tokenPath)
        Restart=always
        RestartSec=3
        KillSignal=SIGTERM
        TimeoutStopSec=50

        [Install]
        WantedBy=multi-user.target
        """

        var script = """
        \(preamble)

        say "Writing systemd unit"
        cat > /etc/systemd/system/\(serviceName).service <<'CODEX_REMOTE_UNIT_EOF'
        \(unit)
        CODEX_REMOTE_UNIT_EOF

        chmod 644 /etc/systemd/system/\(serviceName).service
        systemctl daemon-reload
        systemctl enable \(serviceName).service >/dev/null 2>&1
        systemctl restart \(serviceName).service

        say "Waiting for the app-server to answer"
        ok=0
        for i in $(seq 1 45); do
          if curl -fsS -m 3 "http://127.0.0.1:\(plan.remotePort)/healthz" >/dev/null 2>&1; then ok=1; break; fi
          sleep 2
        done
        if [ "$ok" != "1" ]; then
          echo "--- \(serviceName) status ---" >&2
          systemctl status \(serviceName).service --no-pager -l >&2 || true
          echo "--- last 80 journal lines ---" >&2
          journalctl -u \(serviceName).service -n 80 --no-pager >&2 || true
          die "the Codex app-server did not start listening on 127.0.0.1:\(plan.remotePort)"
        fi
        say "app-server healthy on 127.0.0.1:\(plan.remotePort)"
        """

        if plan.idleShutdownMinutes > 0 {
            script += "\n\n" + idleShutdownUnit(minutes: plan.idleShutdownMinutes, port: plan.remotePort)
        }
        return script
    }

    /// Optional cost control: power the box off after N minutes with no Codex websocket
    /// connection and no logged-in shell.
    static func idleShutdownUnit(minutes: Int, port: Int) -> String {
        """
        say "Installing idle shutdown after \(minutes) minutes"
        cat > /usr/local/bin/codex-remote-idle-check <<'CODEX_REMOTE_IDLE_EOF'
        #!/usr/bin/env bash
        set -euo pipefail
        STAMP=/var/lib/codex-remote-idle-since
        busy=0
        # An established connection to the app-server port means someone is working.
        if ss -Htn "sport = :\(port)" 2>/dev/null | grep -q ESTAB; then busy=1; fi
        # A live login shell counts too.
        if who | grep -q .; then busy=1; fi
        if [ "$busy" = "1" ]; then rm -f "$STAMP"; exit 0; fi
        now=$(date +%s)
        if [ ! -f "$STAMP" ]; then echo "$now" > "$STAMP"; exit 0; fi
        since=$(cat "$STAMP")
        if [ $(( (now - since) / 60 )) -ge \(minutes) ]; then
          logger -t codex-remote "idle for \(minutes) minutes; powering off"
          /sbin/shutdown -h now
        fi
        CODEX_REMOTE_IDLE_EOF
        chmod 755 /usr/local/bin/codex-remote-idle-check

        cat > /etc/systemd/system/codex-remote-idle.service <<'CODEX_REMOTE_IDLE_SVC_EOF'
        [Unit]
        Description=Codex Remote idle shutdown check
        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/codex-remote-idle-check
        CODEX_REMOTE_IDLE_SVC_EOF

        cat > /etc/systemd/system/codex-remote-idle.timer <<'CODEX_REMOTE_IDLE_TIMER_EOF'
        [Unit]
        Description=Run the Codex Remote idle check every minute
        [Timer]
        OnBootSec=5min
        OnUnitActiveSec=1min
        [Install]
        WantedBy=timers.target
        CODEX_REMOTE_IDLE_TIMER_EOF

        systemctl daemon-reload
        systemctl enable --now codex-remote-idle.timer >/dev/null 2>&1 || true
        """
    }

    /// Keeps Codex's dial-out remote control up across reboots.
    ///
    /// `codex remote-control start` bootstraps a daemon that Codex itself supervises by
    /// pid — nothing brings it back after a reboot, so a machine you powered off would
    /// quietly drop out of "Control other devices" on the way back up. This unit re-runs
    /// the same supported command at boot.
    ///
    /// `Type=oneshot` with `RemainAfterExit`, because the command bootstraps the daemon and
    /// returns rather than staying in the foreground. That means systemd tracks whether the
    /// *start* succeeded, not the daemon's health; the honest alternative would be running
    /// codex's internal `--managed-daemon` invocation directly, which is undocumented and
    /// would break the moment they change it.
    public static func installRemoteControlService(_ plan: BootstrapPlan) -> String {
        let home = "/\(plan.serviceUser == "root" ? "root" : "home/\(plan.serviceUser)")"
        let unit = """
        [Unit]
        Description=Codex Remote — Codex remote control
        Documentation=https://learn.chatgpt.com/docs/remote-connections
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        User=\(plan.serviceUser)
        Environment=HOME=\(home)
        Environment=CODEX_HOME=\(home)/.codex
        ExecStart=/usr/local/bin/codex remote-control start --json
        ExecStop=/usr/local/bin/codex remote-control stop
        Restart=on-failure
        RestartSec=10

        [Install]
        WantedBy=multi-user.target
        """

        return """
        \(preamble)

        command -v codex >/dev/null || die "codex is not installed on this machine"

        say "Installing the Codex remote control service"
        cat > /etc/systemd/system/\(remoteControlServiceName).service <<'CODEX_REMOTE_RC_UNIT_EOF'
        \(unit)
        CODEX_REMOTE_RC_UNIT_EOF

        chmod 644 /etc/systemd/system/\(remoteControlServiceName).service
        systemctl daemon-reload
        systemctl enable \(remoteControlServiceName).service >/dev/null 2>&1
        systemctl restart \(remoteControlServiceName).service
        say "Codex remote control will come back on its own after a reboot"
        """
    }

    // MARK: - Claude Code

    /// Installs Claude Code and gets it past the two things that stop it starting on a
    /// machine nobody is sitting at.
    ///
    /// Claude Code's first run is a wizard — it asks for a theme and whether the working
    /// directory is trusted — and it will sit on that forever under a service manager. The
    /// answers live in `~/.claude.json`, so they are written before the first launch.
    public static func installClaudeCode(_ plan: BootstrapPlan) -> String {
        let user = plan.claudeUser
        let home = plan.claudeHome
        return """
        \(preamble)

        say "Creating the \(user) account"
        if ! id -u \(user) >/dev/null 2>&1; then
          useradd --create-home --shell /bin/bash \(user)
        fi
        # No password login; the account is reached over SSH with Codex Remote's key, or via su.
        passwd -l \(user) >/dev/null 2>&1 || true

        # A coding agent on a disposable box needs to install packages to be useful, so the
        # account gets passwordless sudo. It is still not root: Claude Code's most permissive
        # mode works, file ownership is its own, and a mistake is contained to the account
        # until it deliberately escalates.
        # Written to a temp file and validated before it is moved into place: a sudoers
        # drop-in that does not parse takes sudo down for everyone, root included. Note
        # this is a plain redirect rather than `install /dev/stdin`, which fails with
        # ENOENT when the destination already exists — as it does on every repair.
        cat > /etc/sudoers.d/.90-codex-remote-\(user).new <<'CODEX_REMOTE_SUDO_EOF'
        \(user) ALL=(ALL) NOPASSWD:ALL
        CODEX_REMOTE_SUDO_EOF
        chmod 0440 /etc/sudoers.d/.90-codex-remote-\(user).new
        visudo -cf /etc/sudoers.d/.90-codex-remote-\(user).new >/dev/null
        mv /etc/sudoers.d/.90-codex-remote-\(user).new /etc/sudoers.d/90-codex-remote-\(user)

        # Codex Remote's key works for the agent account too, so `ssh \(user)@machine` is there
        # when you want to look around as the agent sees things.
        mkdir -p \(home)/.ssh
        if [ -f /root/.ssh/authorized_keys ]; then
          cp /root/.ssh/authorized_keys \(home)/.ssh/authorized_keys
        fi
        chmod 700 \(home)/.ssh
        chmod 600 \(home)/.ssh/authorized_keys 2>/dev/null || true
        chown -R \(user):\(user) \(home)/.ssh

        say "Preparing the workspace at \(plan.claudeWorkspace)"
        mkdir -p '\(plan.claudeWorkspace)'
        chown -R \(user):\(user) '\(plan.claudeWorkspace)'
        # setgid so anything created inside stays group-writable for both agents.
        chmod 2775 '\(plan.claudeWorkspace)'

        say "Installing Claude Code for \(user)"
        su - \(user) -c 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null

        claude_bin="\(home)/.local/bin/claude"
        [ -x "$claude_bin" ] || die "Claude Code did not install for \(user)"
        ln -sf "$claude_bin" /usr/local/bin/claude

        if ! grep -q '.local/bin' \(home)/.bashrc 2>/dev/null; then
          echo 'export PATH="$HOME/.local/bin:$PATH"' >> \(home)/.bashrc
        fi

        say "Skipping the first-run wizard"
        su - \(user) -c 'python3 - <<"CODEX_REMOTE_CLAUDE_SEED_EOF"
        import json, os
        home = os.path.expanduser("~")
        path = os.path.join(home, ".claude.json")
        try:
            data = json.load(open(path))
        except Exception:
            data = {}
        data["hasCompletedOnboarding"] = True
        # `claude remote-control` asks "Enable Remote Control? (y/n)" the first time and
        # waits forever for an answer under a service manager. This is the answer.
        data["remoteDialogSeen"] = True
        data.setdefault("theme", "dark")
        projects = data.setdefault("projects", {})
        projects.setdefault("\(plan.claudeWorkspace)", {})["hasTrustDialogAccepted"] = True
        json.dump(data, open(path, "w"), indent=2)

        os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
        settings_path = os.path.join(home, ".claude", "settings.json")
        try:
            settings = json.load(open(settings_path))
        except Exception:
            settings = {}
        settings.setdefault("theme", "dark")
        json.dump(settings, open(settings_path, "w"), indent=2)
        CODEX_REMOTE_CLAUDE_SEED_EOF'

        # A machine set up before the agent had its own account has the login in root's
        # home. Move it across rather than making the user approve a second browser
        # sign-in for a machine that is already authorised — it is the same credential on
        # the same machine, and root's copy stops being used the moment this runs.
        if [ -s /root/.claude/.credentials.json ] && [ ! -s \(home)/.claude/.credentials.json ]; then
          say "Moving the existing Claude login to \(user)"
          # Stop root's agent first. It holds the credential in memory and rewrites the
          # file whenever it refreshes, and a refresh rotates the refresh token — so a
          # copy taken while it runs can be stale before the new service ever starts.
          systemctl stop \(Self.claudeServiceName) 2>/dev/null || true
          mkdir -p \(home)/.claude
          mv /root/.claude/.credentials.json \(home)/.claude/.credentials.json
          chown -R \(user):\(user) \(home)/.claude
          chmod 600 \(home)/.claude/.credentials.json
        fi

        echo "CLAUDE_BIN=/usr/local/bin/claude"
        echo "CLAUDE_USER=\(user)"
        echo "CLAUDE_WORKSPACE=\(plan.claudeWorkspace)"
        echo "CLAUDE_VERSION=$(su - \(user) -c '\(home)/.local/bin/claude --version' 2>/dev/null | head -1)"
        say "Claude Code installed for \(user)"
        """
    }

    /// The unit that keeps a Remote Control session signed in and reachable from the user's
    /// account.
    ///
    /// `claude --remote-control` is an interactive session — without a terminal it falls
    /// through to `--print` and exits complaining about missing input. `script` gives it a
    /// pty, which is what makes it survivable under systemd.
    public static func installClaudeService(_ plan: BootstrapPlan, sessionName: String) -> String {
        let user = plan.claudeUser
        let home = plan.claudeHome
        let unit = """
        [Unit]
        Description=Codex Remote — Claude Code Remote Control
        Documentation=https://code.claude.com/docs
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        User=\(user)
        Group=\(user)
        Environment=HOME=\(home)
        Environment=TERM=xterm-256color
        Environment=PATH=\(home)/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        WorkingDirectory=\(plan.claudeWorkspace)
        # `claude remote-control` (aka `claude rc`) is the HOST side: it registers the
        # machine and spawns sessions on demand, which is what puts it in the Remote
        # Control menu so you can start a new project on it. `claude --remote-control` is
        # a different thing — one interactive session, which shows up in Recents but
        # leaves the menu empty. `script` supplies the pty either of them needs.
        ExecStart=/usr/bin/script -qfec "/usr/local/bin/claude remote-control --name \(sessionName)" /dev/null
        Restart=always
        RestartSec=5
        KillSignal=SIGTERM
        TimeoutStopSec=30
        StandardOutput=append:/var/log/codex-remote-claude.log
        StandardError=append:/var/log/codex-remote-claude.log

        [Install]
        WantedBy=multi-user.target
        """

        return """
        \(preamble)

        test -s \(home)/.claude/.credentials.json \
          || die "no Claude Code credentials on the machine — Codex Remote should have copied them"

        say "Installing the Claude Code service"
        : > /var/log/codex-remote-claude.log
        chown \(user):\(user) /var/log/codex-remote-claude.log
        cat > /etc/systemd/system/\(claudeServiceName).service <<'CODEX_REMOTE_CLAUDE_UNIT_EOF'
        \(unit)
        CODEX_REMOTE_CLAUDE_UNIT_EOF

        chmod 644 /etc/systemd/system/\(claudeServiceName).service

        # The daemon refuses to start if another one already serves this folder ("This
        # folder is already served by a terminal `claude remote-control` on this device").
        # A repair, or anyone who ran it by hand over SSH, can leave one behind — so stop
        # the unit and clear strays before restarting, or the restart loops on exit 1.
        systemctl stop \(claudeServiceName).service 2>/dev/null || true
        pkill -u \(user) -f 'claude remote-control' 2>/dev/null || true
        sleep 2

        systemctl daemon-reload
        systemctl enable \(claudeServiceName).service >/dev/null 2>&1
        systemctl restart \(claudeServiceName).service

        say "Waiting for Remote Control to connect"
        # Two signals, because the first is screen-scraped from a TUI that anything can
        # scroll away — a held message from another session did exactly that, and a healthy
        # machine was reported as failed. A session URL in the log is the stronger signal.
        ok=0
        for i in $(seq 1 60); do
          clean="$(sed 's/\\x1b\\[[0-9;?]*[a-zA-Z]//g' /var/log/codex-remote-claude.log 2>/dev/null || true)"
          case "$clean" in
            *"Connected"*|*"environment=env_"*|*"claude.ai/code/session_"*) ok=1; break ;;
          esac
          if ! systemctl is-active --quiet \(claudeServiceName).service; then break; fi
          sleep 2
        done
        if [ "$ok" != "1" ]; then
          echo "--- \(claudeServiceName) status ---" >&2
          systemctl status \(claudeServiceName).service --no-pager -l >&2 || true
          echo "--- log ---" >&2
          sed 's/\\x1b\\[[0-9;?]*[a-zA-Z]//g' /var/log/codex-remote-claude.log 2>/dev/null | tail -30 >&2 || true
          die "Claude Code did not reach Remote Control"
        fi

        # Both of these are optional extras — the machine is already connected by the time we
        # get here, and the `[ -n ... ]` guards below say as much. They still need `|| true`:
        # the preamble sets `pipefail`, grep exits 1 when it matches nothing, and `set -e`
        # then kills the script *silently*, because grep prints nothing when it finds
        # nothing. That reported a healthy, connected machine as "Claude Remote Control
        # service failed" with no explanation attached, and only when the daemon had not yet
        # printed a session line — so it passed under any tracing slow enough to let one
        # appear, and failed in ordinary use.
        clean="$(sed 's/\\x1b\\[[0-9;?]*[a-zA-Z]//g' /var/log/codex-remote-claude.log)"
        # The session URL is how you reach this machine from anywhere.
        url="$(printf '%s' "$clean" | grep -ao 'https://claude.ai/code/session_[A-Za-z0-9]*' | tail -1 || true)"
        [ -n "$url" ] && echo "CLAUDE_SESSION_URL=$url"
        # The environment is the machine itself — what the Remote Control menu lists, and
        # what you pick when starting a new project on it.
        env_id="$(printf '%s' "$clean" | grep -ao 'env_[A-Za-z0-9]*' | tail -1 || true)"
        [ -n "$env_id" ] && echo "CLAUDE_ENVIRONMENT_ID=$env_id"
        say "Claude Code is live in your account"
        """
    }

    /// Stage 4: extra packages and the user's own setup script — off the critical path.
    ///
    /// Both used to run inline, which meant the machine was not Ready until they finished:
    /// `apt install` of a few packages is a minute, and a setup script that builds a
    /// toolchain or clones a large repo can be many. Nothing about Codex or Claude needs
    /// either of them, so waiting bought nothing.
    ///
    /// They now run as a oneshot unit, started with `--no-block` once the agents are up. The
    /// unit is `RemainAfterExit`, so `systemctl is-active` reads `active` when it finished
    /// and `failed` when it did not, which is how `status` reports it afterwards. Output goes
    /// to a log rather than back over the provisioning connection, because by then there is
    /// nothing on the other end reading it.
    ///
    /// Returns nil when there is nothing to defer.
    public static func deferredSetup(_ plan: BootstrapPlan) -> String? {
        let packages = plan.extraPackages
            .filter { $0.range(of: "^[A-Za-z0-9][A-Za-z0-9+._-]*$", options: .regularExpression) != nil }
            .joined(separator: " ")
        let custom = plan.postSetupScript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !packages.isEmpty || !custom.isEmpty else { return nil }

        let body = """
        \(preamble)

        \(packages.isEmpty ? "" : """
        say "Installing extra packages: \(packages)"
        wait_for_apt
        export DEBIAN_FRONTEND=noninteractive
        $APT install -y -qq \(packages)
        say "Extra packages installed"
        """)

        \(custom.isEmpty ? "" : """
        cd '\(plan.workspacePath)'
        say "Running your post-setup script"
        \(custom)
        say "Post-setup script finished"
        """)
        """

        let unit = """
        [Unit]
        Description=Codex Remote - deferred setup (extra packages and your setup script)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        WorkingDirectory=\(plan.workspacePath)
        ExecStart=/usr/local/lib/codex-remote-setup.sh
        StandardOutput=append:/var/log/codex-remote-setup.log
        StandardError=append:/var/log/codex-remote-setup.log
        """

        return """
        \(preamble)

        install -d /usr/local/lib
        cat > /usr/local/lib/codex-remote-setup.sh <<'CODEX_REMOTE_DEFERRED_EOF'
        \(body)
        CODEX_REMOTE_DEFERRED_EOF
        sed -i 's/^        //' /usr/local/lib/codex-remote-setup.sh
        chmod 0755 /usr/local/lib/codex-remote-setup.sh

        cat > /etc/systemd/system/\(deferredSetupServiceName).service <<'CODEX_REMOTE_DEFERRED_UNIT_EOF'
        \(unit)
        CODEX_REMOTE_DEFERRED_UNIT_EOF
        sed -i 's/^        //' /etc/systemd/system/\(deferredSetupServiceName).service

        systemctl daemon-reload
        # --no-block is the whole point: provisioning reports the machine ready and this
        # carries on by itself.
        systemctl start --no-block \(deferredSetupServiceName).service
        say "Extra setup is running in the background"
        """
    }

    /// Teardown used when a machine is removed but the server is being kept.
    public static func uninstall() -> String {
        """
        \(preamble)
        systemctl disable --now \(serviceName).service >/dev/null 2>&1 || true
        systemctl disable --now \(claudeServiceName).service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/\(claudeServiceName).service
        # The machine's copy of the Claude login goes with it.
        rm -f /root/.claude/.credentials.json /home/\(claudeUser)/.claude/.credentials.json
        systemctl disable --now codex-remote-idle.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/\(serviceName).service /etc/systemd/system/codex-remote-idle.{service,timer}
        rm -f /usr/local/bin/codex-remote-idle-check
        rm -rf \(stateDir)
        systemctl daemon-reload || true
        say "Codex Remote service removed"
        """
    }

    /// Shared header: strict mode, a `say` that the UI can parse, and an apt-lock waiter,
    /// because a freshly booted cloud image is usually mid-`unattended-upgrade`.
    /// Shared by every script Codex Remote runs remotely, so progress and failures come
    /// back through the same two markers the pipeline already parses.
    /// Extra packages and the user's setup script, deferred so they cannot hold up Ready.
    public static let deferredSetupServiceName = "codex-remote-setup"

    static let preamble = """
    set -euo pipefail
    say() { echo "::codex-remote:: $*"; }
    die() { echo "::codex-remote-error:: $*" >&2; exit 1; }
    # A freshly booted cloud image is usually mid-unattended-upgrade. `fuser` is not on
    # every minimal image, so this checks for the processes themselves; apt's own
    # DPkg::Lock::Timeout (set on each apt-get call) is the belt to this pair of braces.
    wait_for_apt() {
      for i in $(seq 1 120); do
        if ! pgrep -x apt-get >/dev/null 2>&1 \
           && ! pgrep -x dpkg >/dev/null 2>&1 \
           && ! pgrep -f unattended-upgr >/dev/null 2>&1; then
          return 0
        fi
        sleep 5
      done
      say "package manager still busy after 10 minutes; continuing and letting apt wait on the lock"
    }
    APT="apt-get -o DPkg::Lock::Timeout=600"
    """
}
