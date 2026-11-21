import Foundation

struct AppCatalog: Decodable {
    let apiVersion: Int
    let apps: [RemoteApp]
}

struct RemoteApp: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let displayName: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let size: Int64
    let platforms: [String]
    let urlSchemes: [String]
    let date: String?
    let minimumOSVersion: String?
    /// Absent sur les serveurs plus anciens.
    let hasIcon: Bool?

    var launchURL: URL? {
        // Schemes used by system services or sign-in providers aren't app launch contracts.
        let excluded = ["http", "https", "file", "itms-services", "tel", "mailto", "sms", "shortcuts", "prefs", "app-settings", "tailscale"]
        guard let scheme = urlSchemes.first(where: {
            !excluded.contains($0.lowercased()) &&
            !$0.lowercased().hasPrefix("com.googleusercontent.") &&
            $0.range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil
        }) else { return nil }
        return URL(string: scheme + "://")
    }
}

/// Tous les builds d'une même app (même identifiant de bundle), du plus récent au plus ancien.
struct AppGroup: Identifiable {
    let id: String
    let builds: [RemoteApp]
    var latest: RemoteApp { builds[0] }
    var older: ArraySlice<RemoteApp> { builds.dropFirst() }

    /// Regroupe en conservant l'ordre du serveur (déjà trié du plus récent au plus ancien).
    static func grouping(_ apps: [RemoteApp]) -> [AppGroup] {
        var order: [String] = []
        var buckets: [String: [RemoteApp]] = [:]
        for app in apps {
            if buckets[app.bundleIdentifier] == nil { order.append(app.bundleIdentifier) }
            buckets[app.bundleIdentifier, default: []].append(app)
        }
        return order.map { AppGroup(id: $0, builds: buckets[$0] ?? []) }
    }
}

/// Dernière installation lancée depuis ce client pour une app. iOS ne permet pas de lire
/// la version réellement installée : c'est l'historique de ServeIPA, pas une vérification.
struct InstallRecord: Codable, Equatable {
    let appID: String
    let version: String
    let build: String
    let date: Date

    /// Vrai si `build` est plus récent que le build de cet enregistrement.
    func isOlder(than app: RemoteApp) -> Bool {
        guard app.id != appID else { return false }
        if let new = Int(app.build), let old = Int(build) { return new > old }
        return app.build.compare(build, options: .numeric) == .orderedDescending
    }
}

/// Recompilation en cours (ou dernière terminée) sur le Mac.
struct RebuildJob: Decodable, Equatable {
    let id: String
    let app: String
    let platform: String
    /// running, succeeded ou failed.
    let state: String
    let step: String
    let error: String?
}

struct InstallTicket: Codable {
    let id: String
    let installURL: URL
    let downloadPath: String
}

struct TransferProgress: Decodable {
    let id: String
    let sent: Int64
    let total: Int64
    let state: String
}

struct PendingInstall: Codable {
    let app: RemoteApp
    let ticket: InstallTicket
    let server: URL
    let createdAt: Date
    let wasDetectable: Bool
    let detectionSupported: Bool
    var didAutoOpen = false
}

enum ClientError: LocalizedError {
    case invalidAddress, incompatibleServer, http(Int), invalidDownload, invalidLink

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Saisissez une adresse HTTPS sans identifiant, chemin, paramètres ni fragment."
        case .incompatibleServer: "Ce serveur ne propose pas l’API ServeIPA v1. Mettez à jour et relancez ServeIPA sur le Mac."
        case .http(let code): "Le serveur a répondu HTTP \(code)."
        case .invalidDownload: "Le fichier reçu ne correspond pas à la taille annoncée. Relancez le téléchargement."
        case .invalidLink: "Le serveur a fourni un lien d’installation inattendu."
        }
    }
}

enum ServerAddress {
    static let defaultValue = "https://lucifer.tail0ad79c.ts.net"

    static func parse(_ text: String) throws -> URL {
        guard var components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ClientError.invalidAddress
        }
        components.path = ""
        guard let url = components.url else { throw ClientError.invalidAddress }
        return url
    }

    static func validate(_ ticket: InstallTicket, server: URL) throws {
        guard UUID(uuidString: ticket.id) != nil,
              ticket.downloadPath == "api/v1/sessions/\(ticket.id)/ipa",
              let install = URLComponents(url: ticket.installURL, resolvingAgainstBaseURL: false),
              install.scheme == "itms-services",
              install.queryItems?.first(where: { $0.name == "action" })?.value == "download-manifest",
              let manifestText = install.queryItems?.first(where: { $0.name == "url" })?.value,
              let manifest = URL(string: manifestText),
              manifest == server.appending(path: "api/v1/sessions/\(ticket.id)/manifest") else {
            throw ClientError.invalidLink
        }
    }
}
