import Foundation

/// Builds the `ProviderDescriptor` for an OpenTofu-backed cloud, optionally pairing it
/// with a native API client for the operations OpenTofu cannot express.
public enum TofuRegistration {
    /// `runtime` returns Codex Remote's own API client for the same cloud, when there is one.
    /// It handles power state, fast status polling, and the New machine form, none of
    /// which OpenTofu models or answers quickly.
    public static func descriptor(
        for module: TofuModule,
        runtime: (@Sendable (ProviderAccount, [String: Secret]) throws -> ComputeProvider)? = nil
    ) -> ProviderDescriptor {
        ProviderDescriptor(
            kind: module.kind,
            displayName: module.displayName,
            blurb: module.blurb,
            credentialFields: module.credentialFields,
            tokenHelpURL: module.tokenHelpURL,
            make: { account, secrets in
                let native = try runtime.flatMap { try $0(account, secrets) }
                return TofuProvider(module: module, account: account,
                                    secrets: secrets, runtime: native)
            }
        )
    }

    /// Every cloud Codex Remote can provision through OpenTofu.
    public static let modules: [TofuModule] = [
        .hetzner, .digitalOcean, .linode, .vultr, .scaleway, .awsEC2,
    ]

    public static func module(for kind: ProviderKind) -> TofuModule? {
        modules.first { $0.kind == kind }
    }
}
