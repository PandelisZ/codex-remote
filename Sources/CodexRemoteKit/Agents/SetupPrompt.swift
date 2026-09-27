import Foundation

/// The prompt behind the empty state's **Copy prompt for your agent** button.
///
/// Setting up the first machine means picking a cloud, a region and a size, and deciding
/// which agents go on it. Those are questions, not a form to guess at — so rather than
/// walking someone through the UI, hand their agent a brief and let it ask.
///
/// It is written for an agent that already has a shell. Everything the menu bar does is
/// scriptable, so `codex-remote` is the whole interface it needs, and the prompt is
/// deliberate about the two things an agent gets wrong unsupervised: spending the user's
/// money without asking, and inventing values for questions it should have asked.
public enum SetupPrompt {
    public static func firstMachine(hasAccount: Bool, cliPath: String) -> String {
        let accountStep = hasAccount
            ? """
            A provider account is already configured. Run `\(cliPath) accounts` to see it, and
            use it unless I say otherwise.
            """
            : """
            No provider account is configured yet. Run `\(cliPath) providers` to see what is
            supported, ask me which cloud I want, and tell me exactly how to get a token for
            it. **Do not ask me to paste the token to you.** Have me add it myself with
            `\(cliPath) account add --provider <kind> --label <name>`, which reads the secret
            from the matching environment variable or from stdin and puts it in my keychain.
            """

        return """
        I want to set up a remote machine for coding agents using Codex Remote, a macOS
        menu bar app that provisions cloud servers and installs Codex and/or Claude Code on
        them. Its CLI is at `\(cliPath)` and everything the app does is scriptable through it.

        Please walk me through it, asking one question at a time and waiting for my answer.

        **First, get your bearings.** Run `\(cliPath) --help` first.
        Do not guess at flags.

        **Then the account.** \(accountStep)

        **Then ask me these, one at a time.** Suggest a sensible default for each, and say
        what it costs me where that applies:

        1. Which cloud, if there is more than one configured.
        2. Which region — nearest to me is usually right; ask where I am.
        3. How big. Run `\(cliPath) capabilities --account <label>` for the real list with
           prices. Note that some accounts can only create certain instance types, so if a
           create fails with a quota or limit error, tell me what it said rather than
           silently trying a different size I did not agree to.
        4. Which agents: Codex, Claude Code, or both (`--agent codex --agent claude`).
        5. Whether to sync my MCP servers over (on by default). Servers that point at paths
           only my Mac has are skipped automatically, and it will tell you which.

        **Then create it**, showing me the command before you run it:

        ```
        \(cliPath) create --account <label> --name <name> [--region r] [--size s] [--agent ...]
        ```

        It takes a few minutes and streams its progress. Do not run it more than once — a
        second run creates a second server I will be billed for. If the menu bar app is
        running it owns the tunnels, and the CLI will tell you to quit it first.

        **Then finish the setup.**

        - Claude Code needs a one-off sign-in on the machine: `\(cliPath) claude-login <name>`.
          It prints a URL for me to approve and asks for the code I get back. The machine
          gets its own login; it never shares this Mac's, because two installs cannot use
          one refresh token.
        - For Codex, the machine is added to `~/.ssh/config`, which is how the Codex app
          finds it. Tell me to relaunch Codex; it reads that file at launch, so a machine
          created while it is open shows up next time.
        - Optionally `\(cliPath) codex-pair <name>` turns on Codex's dial-out remote control
          so I can reach the box from my phone. Pairing needs me to paste a code into Codex
          — that prompt is a security control, so do not try to work around it.

        **Finally, check it worked** with `\(cliPath) status <name>` and tell me in one line
        what I now have and roughly what it costs per month.

        Rules for you: never create, destroy or resize anything without showing me the
        command first and getting a yes. Never put a token in a command line argument.
        If something fails, show me the actual error rather than a summary of it.
        """
    }
}
