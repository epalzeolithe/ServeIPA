import Foundation

/// Version, numéro de build et date de build (du client ou du serveur).
/// Pour le client, les valeurs viennent de Info.plist, écrites par Scripts/build-number.sh.
struct AppBuildInfo: Equatable, Sendable {
    let version: String
    let build: String
    let date: Date?

    nonisolated static let current: AppBuildInfo = {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppBuildInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "—",
            build: info["CFBundleVersion"] as? String ?? "—",
            rawDate: info["ServeIPABuildDate"] as? String
        )
    }()

    init(version: String, build: String, rawDate: String?) {
        self.version = version
        self.build = build
        self.date = rawDate.flatMap { try? Date($0, strategy: .iso8601) }
    }

    /// « 1.0 (12) · 15 nov. 2026 à 15:02 »
    var summary: String {
        var text = "\(version) (\(build))"
        if let date { text += " · " + date.formatted(date: .abbreviated, time: .shortened) }
        return text
    }
}
