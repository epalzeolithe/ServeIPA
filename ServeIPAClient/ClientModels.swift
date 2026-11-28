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
    /// « iOS » ou « macOS » ; absent sur les serveurs plus anciens (qui ne servent que des IPA).
    let platform: String?
    /// Numéro de build du projet Xcode quand il dépasse celui de ce build ; absent sinon (ou serveur ancien).
    let projectBuild: Int?
    /// Date de l'exécutable (secondes depuis 1970) : distingue deux compilations de même numéro. macOS seulement.
    var builtAt: Double? = nil
    /// Vrai pour l'app du serveur ServeIPA lui-même ; absent sur les serveurs plus anciens.
    var isServer: Bool? = nil
    /// Dernier commit et dernier push du projet (secondes depuis 1970), publiés pour le dernier build de chaque
    /// app ; absents hors dépôt git, sans push depuis le Mac serveur ou avec un serveur ancien.
    var lastCommit: Double? = nil
    var lastPush: Double? = nil
    /// Numéro de build de l'app dans ce commit et dans le commit poussé.
    var lastCommitBuild: Int? = nil
    var lastPushBuild: Int? = nil

    var isMac: Bool { platform == "macOS" }

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
    /// Date de l'exécutable installé, quand elle est lisible (Mac).
    var builtAt: Date? = nil

    /// Vrai si la version installée est celle de `app` : même release, ou mêmes version et numéro sans compilation
    /// plus récente connue. Une recompilation à numéro égal change l'identifiant de la release, et sur Mac la version
    /// lue sur le disque n'en a pas.
    func matches(_ app: RemoteApp) -> Bool {
        appID == app.id || (version == app.version && build == app.build && !isOlder(than: app))
    }

    /// Vrai si `app` est plus récente : par sa version, sinon par son numéro de build, sinon, à numéros égaux,
    /// par sa date de compilation.
    func isOlder(than app: RemoteApp) -> Bool {
        guard app.id != appID else { return false }
        if !version.isEmpty, !app.version.isEmpty {
            let order = app.version.compare(version, options: .numeric)
            if order != .orderedSame { return order == .orderedDescending }
        }
        let order = app.build.compare(build, options: .numeric)
        if order != .orderedSame { return order == .orderedDescending }
        guard let builtAt, let remote = app.builtAt else { return false }
        // La copie conserve la date à la seconde près.
        return remote - builtAt.timeIntervalSince1970 > 5
    }
}

/// Compilation en attente, en cours ou terminée sur le Mac.
struct RebuildJob: Decodable, Equatable, Identifiable {
    let id: String
    let app: String
    let platform: String
    /// queued, running, succeeded, failed ou cancelled.
    let state: String
    let step: String
    let error: String?
    /// « maintenance » (baguette magique du Mac) ou « update » (ServeIPA) ; absent sur les anciens serveurs.
    let kind: String?

    var isMaintenance: Bool { kind == "maintenance" }
    var isServerUpdate: Bool { kind == "update" }
    var isFinished: Bool { state != "queued" && state != "running" }

    /// État d'une mise à jour déduit par le client, quand le serveur ne peut pas le publier.
    static func serverUpdate(_ id: String, state: String, text: String) -> RebuildJob {
        RebuildJob(id: id, app: "ServeIPA", platform: "macOS", state: state, step: text,
                   error: state == "failed" ? text : nil, kind: "update")
    }

    /// Titre affiché avant, pendant et après le job.
    func title(on mac: String) -> String {
        if isMaintenance { return state == "running" ? "Baguette magique sur \(mac)" : "Baguette magique" }
        if isServerUpdate { return "Mise à jour du serveur" }
        return state == "running" ? "Recompilation de \(app)" : "\(app) · \(platform)"
    }

    /// Étape en cours, bilan ou erreur.
    var detail: String {
        switch state {
        case "queued": "En file d’attente"
        case "cancelled": "Annulé"
        case "succeeded": isMaintenance || isServerUpdate ? step : "Terminé — le nouveau build est dans la liste."
        case "failed": error ?? "La compilation a échoué."
        default: step
        }
    }
}

/// Projet Xcode trouvé par le scan du Mac (`GET /api/v1/projects`).
struct RemoteProject: Decodable, Identifiable, Equatable {
    struct Platform: Decodable, Equatable {
        let name: String
        /// Un build de cette app existe déjà sur le serveur.
        let served: Bool
    }

    let id: String
    let name: String
    let scheme: String?
    let bundleIdentifier: String?
    let folder: String?
    /// Raison pour laquelle l'app ne peut pas être ajoutée.
    let problem: String?
    let platforms: [Platform]
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

/// Date d'une app telle qu'elle est affichée : « 25 nov 16:25 », avec l'année si ce n'est pas l'année en cours.
nonisolated enum AppDate {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        var style = Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        // Sans le point d'abréviation (« nov. »).
        let day = date.formatted(style).replacingOccurrences(of: ".", with: "")
        let time = calendar.dateComponents([.hour, .minute], from: date)
        return day + String(format: " %02d:%02d", time.hour ?? 0, time.minute ?? 0)
    }
}
