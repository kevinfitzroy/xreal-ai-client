import Foundation

enum AppVersion {
    static var display: String {
        let p = parts
        return "v\(p.version) · build \(p.revision)-\(p.build)"
    }

    static var logPanelDisplay: String {
        let p = parts
        return "v\(p.version)\nbuild \(p.revision)-\(p.build)"
    }

    private static var parts: (version: String, build: String, revision: String) {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String)?.nilIfEmpty ?? "0.0.0"
        let build = (info?["CFBundleVersion"] as? String)?.nilIfEmpty ?? "0"
        let revision = (info?["AgentStationGitRevision"] as? String)?.nilIfEmpty ?? "unknown"
        return (version, build, revision)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
