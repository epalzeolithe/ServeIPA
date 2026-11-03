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
