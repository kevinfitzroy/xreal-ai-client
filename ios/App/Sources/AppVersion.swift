import Foundation

enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String)?.nilIfEmpty ?? "0.0.0"
        let build = (info?["CFBundleVersion"] as? String)?.nilIfEmpty ?? "0"
        let revision = (info?["AgentStationGitRevision"] as? String)?.nilIfEmpty ?? "unknown"
        return "v\(version) · build \(revision)-\(build)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
