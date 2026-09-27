import Foundation

/// Runs `tofu init -backend=false` + `tofu validate` over every module's generated HCL.
///
/// Most of Codex Remote's clouds cannot be exercised live without an account on each, so this is
/// the gate that keeps their configuration honest: it downloads each provider plugin and
/// checks the HCL against that provider's real schema, which catches a misspelt attribute
/// or a removed argument without creating anything or spending anything.
public enum TofuValidator {
    public struct Report: Sendable {
        public let kind: ProviderKind
        public let displayName: String
        public let target: String       // "machine" or "catalogue"
        public let passed: Bool
        public let detail: String?
    }

    public static func validateAll(
        modules: [TofuModule] = TofuRegistration.modules,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> [Report] {
        var reports: [Report] = []
        for module in modules {
            reports.append(await validate(module: module, catalogue: false, onProgress: onProgress))
            if module.catalogConfiguration() != nil {
                reports.append(await validate(module: module, catalogue: true, onProgress: onProgress))
            }
        }
        return reports
    }

    public static func validate(module: TofuModule, catalogue: Bool,
                                onProgress: (@Sendable (String) -> Void)? = nil) async -> Report {
        let target = catalogue ? "catalogue" : "machine"
        let label = "\(module.displayName) \(target)"
        onProgress?("Validating \(label)")

        guard let configuration = catalogue ? module.catalogConfiguration()
                                            : module.machineConfiguration() else {
            return Report(kind: module.kind, displayName: module.displayName,
                          target: target, passed: true, detail: "no configuration")
        }

        let workdir = TofuRunner.shared.home
            .appendingPathComponent("validate/\(module.kind.rawValue)-\(target)", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: workdir)
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            try configuration.write(to: workdir.appendingPathComponent("main.tf"),
                                    atomically: true, encoding: .utf8)

            // `-backend=false` keeps this from writing any state; validation only needs
            // the provider schema.
            try await TofuRunner.shared.run(
                .init(["init", "-no-color", "-input=false", "-backend=false"],
                      workdir: workdir, timeout: 600))
            try await TofuRunner.shared.run(
                .init(["validate", "-no-color"], workdir: workdir, timeout: 180))

            return Report(kind: module.kind, displayName: module.displayName,
                          target: target, passed: true, detail: nil)
        } catch {
            return Report(kind: module.kind, displayName: module.displayName,
                          target: target, passed: false,
                          detail: error.localizedDescription)
        }
    }
}
