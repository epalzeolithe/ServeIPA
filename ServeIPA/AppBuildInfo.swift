import Foundation

/// Version, numéro de build et date de build écrits dans Info.plist par Scripts/build-number.sh.
struct AppBuildInfo: Equatable, Sendable {
    let version: String
    let build: String
    let date: Date?

    nonisolated static let current: AppBuildInfo = {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppBuildInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "—",
            build: info["CFBundleVersion"] as? String ?? "—",
            date: (info["ServeIPABuildDate"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        )
    }()

    /// Date ISO 8601 brute, telle que publiée par l'API.
    nonisolated static var rawDate: String? {
        Bundle.main.infoDictionary?["ServeIPABuildDate"] as? String
    }

    /// « 1.0 (12) · 15 nov. 2026 à 15:02 »
    var summary: String {
        var text = "\(version) (\(build))"
        if let date { text += " · " + date.formatted(date: .abbreviated, time: .shortened) }
        return text
    }
}
