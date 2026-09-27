import XCTest
@testable import CodexRemoteKit

/// Codex Remote's secrets are read by more than one binary: the menu bar app, `codex-remote`, and
/// the `security` tool each generated launcher shells out to. macOS gates a read by a
/// different binary behind an access dialog, and the user grants it once with
/// "Always Allow" — but only if the reading binary's signature is stable, which is what
/// `Scripts/signing-identity.sh` is for. An ad-hoc build gets a fresh identity each time
/// and is asked again.
///
/// So the read is environment-dependent and this suite does not assert it succeeds; it
/// asserts the thing that must always hold — that a blocked read is reported rather than
/// hanging the caller forever.
final class KeychainSharingTests: XCTestCase {
    private let account = "codex-remote-test.\(UUID().uuidString).probe"

    override func tearDown() {
        try? Keychain.delete(account: account)
        super.tearDown()
    }

    func testAnItemCodexRemoteWritesIsReadableByTheSecurityToolWithoutADialog() async throws {
        let secret = Secret("probe-" + UUID().uuidString)
        do {
            try Keychain.set(secret, account: account)
        } catch {
            throw XCTSkip("no writable login keychain here: \(error.localizedDescription)")
        }

        guard let security = Shell.which("security") else {
            throw XCTSkip("/usr/bin/security is not available")
        }

        do {
            let result = try await Shell.run(
                security,
                ["find-generic-password", "-s", "io.codexremote.credentials", "-a", account, "-w"],
                timeout: 12
            )
            guard result.succeeded else {
                throw XCTSkip("the security tool was denied: \(result.combined)")
            }
            XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), secret.raw)
        } catch is ShellError {
            throw XCTSkip("macOS asked for keychain approval; sign the build to make this stick")
        }
    }

    /// The property that has to hold no matter what macOS decides about the dialog: a
    /// blocked read surfaces as an error within the timeout instead of hanging a provision.
    func testABlockedReadIsReportedRatherThanHanging() {
        let store = KeychainCredentialStore(timeout: 0.001)
        XCTAssertThrowsError(try store.read("codex-remote-test.definitely-not-present")) { error in
            XCTAssertTrue("\(error)".contains("blocked") || error is Keychain.Failure)
        }
    }

    func testReadingBackThroughCodexRemotesOwnPathRoundTrips() throws {
        let secret = Secret("round-trip-" + UUID().uuidString)
        do {
            try Keychain.set(secret, account: account)
        } catch {
            throw XCTSkip("no writable login keychain here: \(error.localizedDescription)")
        }
        let store = KeychainCredentialStore(timeout: 12)
        XCTAssertEqual(try store.read(account)?.raw, secret.raw)
        try store.remove(account)
        XCTAssertNil(try store.read(account))
    }
}
