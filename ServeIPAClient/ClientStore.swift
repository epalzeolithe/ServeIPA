import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Différences entre iOS et macOS. Le client iOS installe des IPA par OTA ; le client Mac liste les apps macOS
/// du serveur et les installe dans /Applications.
@MainActor
enum Platform {
    #if os(macOS)
    static let isMac = true
    static var isActive: Bool { NSApplication.shared.isActive }
    static func canOpen(_ url: URL) -> Bool { false }
    static func open(_ url: URL) async -> Bool { NSWorkspace.shared.open(url) }
    #else
    static let isMac = false
    static var isActive: Bool { UIApplication.shared.applicationState == .active }
    static func canOpen(_ url: URL) -> Bool { UIApplication.shared.canOpenURL(url) }
    static func open(_ url: URL) async -> Bool { await UIApplication.shared.open(url) }
    #endif

    /// Plateforme des builds affichés par ce client.
    static var serverPlatform: String { isMac ? "macOS" : "iOS" }
}

@MainActor
@Observable
final class ClientStore {
    var address = UserDefaults.standard.string(forKey: "serverAddress") ?? ServerAddress.defaultValue
    var autoOpen = UserDefaults.standard.bool(forKey: "autoOpen") {
        didSet { UserDefaults.standard.set(autoOpen, forKey: "autoOpen") }
    }
    var apps: [RemoteApp] = []
    /// Version et build du serveur Mac (nil si le serveur ne les publie pas encore).
    var serverInfo: AppBuildInfo?
    /// Dernière installation lancée depuis ce client, par identifiant de bundle.
    private(set) var installHistory: [String: InstallRecord] = {
        guard let data = UserDefaults.standard.data(forKey: "installHistory"),
              let saved = try? JSONDecoder().decode([String: InstallRecord].self, from: data) else { return [:] }
        return saved
    }()
    var connectionMessage = "Connexion au serveur…"
    var isConnected = false
    /// Nom d'hôte du Mac serveur (absent sur les anciens serveurs).
    var serverHostName: String?
    /// Nom donné au Mac serveur ; absent sur les anciens serveurs.
    var serverComputerName: String?
    /// Nom à afficher pour le Mac serveur, ou « le Mac » s'il n'est pas connu.
    var serverMacName: String { Self.macName(computerName: serverComputerName, hostName: serverHostName) }

    nonisolated static func macName(computerName: String?, hostName: String?) -> String {
        if let computerName, !computerName.isEmpty { return computerName }
        // Un nom d'hôte venu du fournisseur d'accès (adresse en clair) n'est pas un nom de Mac.
        if let hostName, !hostName.isEmpty {
            let parts = hostName.split(separator: ".")
            if parts.count == 1 || parts.last == "local" { return String(parts[0]) }
        }
        return "le Mac"
    }
    /// Dernière actualisation réussie.
    var lastContact: Date?
    var isLoading = false
    var errorMessage: String?
    var pending: PendingInstall?
    var transfer: TransferProgress?
    var installMessage: String?
    var downloadedFile: URL?
    var downloadingAppID: String?
    var downloadMessage: String?
    /// Dernier message de réussite : affiché comme tel, puis effacé après quelques secondes.
    private(set) var successMessage: String?
    /// Jobs terminés dont la fermeture est programmée.
    var scheduledDismissals: Set<String> = []
    /// Apps installées dans Applications (macOS), par identifiant de bundle ; relues à chaque actualisation.
    #if os(macOS)
    private(set) var installedApps: [String: InstalledApp] = [:]
    /// Mise à jour groupée en cours : app traitée (à partir de 0) sur le total.
    var updateBatch: (index: Int, total: Int)?
    var isCompilingUpdates = false
    /// App qui refuse de quitter, en attente d'un accord pour la forcer.
    var quitRequest: QuitRequest?
    #endif
    /// Compilations du Mac : celle en cours (ou la dernière), la file et les terminées (voir ClientJobs.swift).
    var rebuildJob: RebuildJob?
    var queuedJobs: [RebuildJob] = []
    var jobHistory: [RebuildJob] = []
    /// Résultats déduits par ce client, absents de l'historique du serveur.
    var localResults: [RebuildJob] = []
    var knownFinishedIDs: Set<String>?
    var serverUpdate: ServerUpdateTracking?
    var serverUpdateDetail: String?
    /// Projets sur lesquels rClaude exécute un prompt, vus par le serveur.
    var activePromptProjects: [String] = []
    /// Dernière révision de la liste des apps signalée par le serveur.
    var catalogRevision: String?
    /// Jobs lancés d'ici, déjà notifiés et fermés ; conservés d'un lancement à l'autre.
    var ownedJobIDs = UserDefaults.standard.stringArray(forKey: "ownedJobs") ?? [] {
        didSet { UserDefaults.standard.set(ownedJobIDs, forKey: "ownedJobs") }
    }
    var notifiedJobIDs = UserDefaults.standard.stringArray(forKey: "notifiedJobs") ?? [] {
        didSet { UserDefaults.standard.set(notifiedJobIDs, forKey: "notifiedJobs") }
    }
    var dismissedJobIDs = UserDefaults.standard.stringArray(forKey: "dismissedJobs") ?? [] {
        didSet { UserDefaults.standard.set(dismissedJobIDs, forKey: "dismissedJobs") }
    }
    /// Apps dont une compilation demandée d'ici vient d'aboutir : leur release n'est pas notifiée une seconde fois.
    var ownBuiltApps: Set<String> = []
    /// Suivi de la connexion pour les notifications.
    var failedRefreshes = 0
    var hasReachedServer = false
    /// Job demandé pour chaque projet ajouté depuis ce client (clé : `projectKey`).
    var requestedProjects: [String: String] = [:]
    /// Apps (identifiants de bundle) dont l'installation demandée attend la fin d'une compilation.
    private var compilingInstalls: Set<String> = []
    private var downloadTask: Task<Void, Never>?
    /// Moment où le Mac a fini de transmettre l'IPA, pour fermer le suivi automatiquement (iOS).
    private var transferCompletedAt: Date?
    private let launchDate = Date()
    private var operationID = UUID()

    let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init() {
        if let data = UserDefaults.standard.data(forKey: "pendingInstall"),
           let saved = try? JSONDecoder().decode(PendingInstall.self, from: data),
           Date().timeIntervalSince(saved.createdAt) < 86_400 {
            pending = saved
        }
    }

    func saveAddress(_ value: String) async -> Bool {
        do {
            let url = try ServerAddress.parse(value)
            operationID = UUID()
            resetJobs()
            resetAlerts()
            cancelDownload()
            address = url.absoluteString
            UserDefaults.standard.set(address, forKey: "serverAddress")
            apps = []
            clearPending()
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refresh() async {
        #if os(macOS)
        await reloadInstalledApps()
        #endif
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let requestedAddress = address
        do {
            let base = try ServerAddress.parse(requestedAddress)
            let data = try await request(base.appending(path: "api/v1/health"))
            struct Health: Decodable {
                let service: String
                let apiVersion: Int
                let serverVersion: String?
                let serverBuild: String?
                let serverBuildDate: String?
                let hostName: String?
                let computerName: String?
            }
            guard let health = try? JSONDecoder().decode(Health.self, from: data),
                  health.service == "ServeIPA", health.apiVersion == 1 else {
                throw ClientError.incompatibleServer
            }
            let info = health.serverBuild.map {
                AppBuildInfo(version: health.serverVersion ?? "—", build: $0, rawDate: health.serverBuildDate)
            }
            var catalogComponents = URLComponents(url: base.appending(path: "api/v1/apps"), resolvingAgainstBaseURL: false)
            if Platform.isMac { catalogComponents?.queryItems = [URLQueryItem(name: "platform", value: "macOS")] }
            guard let catalogURL = catalogComponents?.url else { throw ClientError.invalidAddress }
            let catalogData = try await request(catalogURL)
            let catalog = try JSONDecoder().decode(AppCatalog.self, from: catalogData)
            guard catalog.apiVersion == 1 else { throw ClientError.incompatibleServer }
            guard address == requestedAddress else { return }
            // Un ancien serveur ne publie pas la plateforme et ne sert que des IPA iOS.
            apps = catalog.apps.filter { ($0.isMac) == Platform.isMac }
            serverInfo = info
            serverHostName = health.hostName
            serverComputerName = health.computerName
            lastContact = Date()
            isConnected = true
            connectionMessage = base.host?.hasSuffix(".ts.net") == true
                ? "Serveur Tailscale accessible" : "Serveur accessible"
            announceConnection(reached: true)
            announceReleases()
        } catch {
            guard address == requestedAddress else { return }
            isConnected = false
            apps = []
            serverInfo = nil
            if case ClientError.http(404) = error {
                connectionMessage = ClientError.incompatibleServer.localizedDescription
            } else {
                connectionMessage = error.localizedDescription + " Vérifiez Tailscale, l’adresse et le serveur Mac."
            }
            announceConnection(reached: false)
        }
    }

    func monitor() async {
        #if os(macOS)
        reportFailedSelfUpdate()
        #endif
        ClientNotifications.shared.requestAuthorization()
        await refresh()
        var cycle = 0
        while !Task.isCancelled {
            await pollRebuild()
            await pollInstallation()
            // Toutes les minutes environ, le catalogue est relu pour repérer les nouvelles releases.
            cycle += 1
            if cycle % 30 == 0, serverUpdate == nil, downloadingAppID == nil { await refresh() }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func install(_ app: RemoteApp) async {
        #if !os(macOS)
        if isOwnApp(app) {
            await pollRebuild()
            if let message = installBlockedMessage(app) {
                errorMessage = message
                return
            }
        }
        #endif
        #if os(macOS)
        await installMac(app)
        #else
        do {
            let base = try ServerAddress.parse(address)
            let ticket = try await createTicket(app, server: base)
            let launchURL = app.launchURL
            let declared = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
            let supported = launchURL.map { declared.contains($0.scheme ?? "") } ?? false
            let detected = supported && launchURL.map { Platform.canOpen($0) } == true
            transferCompletedAt = nil
            pending = PendingInstall(app: app, ticket: ticket, server: base, createdAt: Date(),
                                     wasDetectable: detected, detectionSupported: supported)
            transfer = nil
            installMessage = "Demande envoyée à iOS : confirmez l’installation."
            persistPending()
            guard await Platform.open(ticket.installURL) else {
                clearPending()
                throw ClientError.invalidLink
            }
            installHistory[app.bundleIdentifier] = InstallRecord(
                appID: app.id, version: app.version, build: app.build, date: Date()
            )
            if let data = try? JSONEncoder().encode(installHistory) {
                UserDefaults.standard.set(data, forKey: "installHistory")
            }
        } catch { errorMessage = error.localizedDescription }
        #endif
    }

    #if os(macOS)
    /// Dossier d'installation des apps macOS.
    nonisolated static let applicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// Dernier build de chaque app installée dont la version installée est plus ancienne que celle du serveur.
    var outdatedInstalledApps: [RemoteApp] {
        AppGroup.grouping(apps).map(\.latest).filter {
            installBlockedMessage($0) == nil && installedApp($0)?.record.isOlder(than: $0) == true
        }
    }

    struct InstalledApp: Sendable {
        let url: URL
        let version: String
        let build: String
        let builtAt: Date?
    }

    /// Identifiant, version, build et date d'exécutable d'un bundle, lus sur le disque.
    nonisolated static func installedInfo(_ url: URL) -> (identifier: String, version: String, build: String, builtAt: Date?)? {
        guard let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              let build = info["CFBundleVersion"] as? String else { return nil }
        let builtAt = (info["CFBundleExecutable"] as? String).flatMap { name in
            let path = url.appending(path: "Contents/MacOS/\(name)").path
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        return (identifier, info["CFBundleShortVersionString"] as? String ?? "", build, builtAt)
    }

    func reloadInstalledApps() async {
        installedApps = await Task.detached { Self.scanInstalledApps() }.value
    }

    /// Lit les apps de /Applications et ~/Applications. LaunchServices n'est pas fiable ici : il connaît toutes les copies
    /// (DerivedData, exports) et n'est pas toujours à jour après un remplacement. On lit donc directement les Info.plist
    /// (Bundle garderait en cache l'ancienne version d'un chemin remplacé).
    nonisolated private static func scanInstalledApps() -> [String: InstalledApp] {
        let fileManager = FileManager.default
        var found: [String: InstalledApp] = [:]
        for root in [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     fileManager.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)] {
            let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names where name.hasSuffix(".app") {
                let url = root.appending(path: name, directoryHint: .isDirectory)
                guard let info = installedInfo(url) else { continue }
                // En cas de doublon, /Applications (lu en premier) l'emporte.
                if found[info.identifier] == nil {
                    found[info.identifier] = InstalledApp(url: url, version: info.version, build: info.build,
                                                          builtAt: info.builtAt)
                }
            }
        }
        return found
    }

    /// Version réellement installée sur ce Mac.
    func installedApp(_ app: RemoteApp) -> (url: URL, record: InstallRecord)? {
        guard let installed = installedApps[app.bundleIdentifier] else { return nil }
        return (installed.url, InstallRecord(appID: "", version: installed.version, build: installed.build, date: Date(),
                                              builtAt: installed.builtAt))
    }
    #endif

    func pollInstallation() async {
        guard var pending else { return }
        guard Date().timeIntervalSince(pending.createdAt) < 86_400 else {
            installMessage = "Suivi expiré. Vous pouvez relancer l’installation."
            return
        }
        do {
            let data = try await request(pending.server.appending(path: "api/v1/sessions/\(pending.ticket.id)"))
            let progress = try JSONDecoder().decode(TransferProgress.self, from: data)
            guard self.pending?.ticket.id == pending.ticket.id else { return }
            transfer = progress
            switch progress.state {
            case "transferred":
                installMessage = "IPA transmis à iOS (fin d’installation non confirmée)."
            case "transferring":
                installMessage = "Transfert de l’IPA…"
            case "failed":
                installMessage = "Transfert interrompu. Relancez l’installation."
            default:
                installMessage = "En attente d’iOS : confirmez l’installation."
            }
            // Detect only a transition from absent to available. An existing app proves no update.
            if pending.detectionSupported, !pending.wasDetectable,
               let url = pending.app.launchURL, Platform.canOpen(url) {
                installMessage = "L’app est maintenant ouvrable. La version installée n’est pas vérifiable."
                if autoOpen, !pending.didAutoOpen, progress.state == "transferred",
                   Platform.isActive {
                    pending.didAutoOpen = true
                    self.pending = pending
                    persistPending()
                    _ = await Platform.open(url)
                }
            }
            #if os(iOS)
            if progress.state == "transferred", isOwnUpdate(pending) {
                await quitForUpdate()
                return
            }
            #endif
            closeTrackingIfDone(pending, state: progress.state)
        } catch {
            guard self.pending?.ticket.id == pending.ticket.id else { return }
            installMessage = "Suivi indisponible : \(error.localizedDescription)"
        }
    }

    #if os(iOS)
    /// Mise à jour de ce client demandée depuis son lancement. Un suivi repris d'un lancement précédent ne compte
    /// pas : la nouvelle version, relancée avant la fin du suivi, se fermerait à son tour.
    private func isOwnUpdate(_ pending: PendingInstall) -> Bool {
        pending.app.bundleIdentifier == Bundle.main.bundleIdentifier && pending.createdAt >= launchDate
    }

    /// iOS n'installe pas une nouvelle version par-dessus une app restée à l'écran : une fois l'IPA transmis,
    /// le client se ferme.
    private func quitForUpdate() async {
        installMessage = "IPA transmis : le client se ferme pour se mettre à jour. Rouvrez-le ensuite."
        // Le temps de lire le message.
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        clearPending()
        UserDefaults.standard.synchronize()
        exit(0)
    }
    #endif

    /// Ferme le suivi une fois l'IPA transmis : après 2 secondes pour laisser lire le message,
    /// ou, si l'ouverture automatique attend l'apparition de l'app, dès qu'elle est ouverte (2 min au plus).
    private func closeTrackingIfDone(_ pending: PendingInstall, state: String) {
        guard state == "transferred" else {
            transferCompletedAt = nil
            return
        }
        let completedAt = transferCompletedAt ?? Date()
        transferCompletedAt = completedAt
        let waitsForAutoOpen = autoOpen && pending.detectionSupported && !pending.wasDetectable
            && !(self.pending?.didAutoOpen ?? false)
        let delay: TimeInterval = waitsForAutoOpen ? 120 : 2
        // Marge d'une demi-seconde : la vérification a lieu toutes les 2 s et ne doit pas rater l'échéance d'un cycle.
        if Date().timeIntervalSince(completedAt) >= delay - 0.5 { clearPending() }
    }

    /// Demande au Mac de recompiler l'app (même plateforme que ce build). Retourne l'identifiant du job, nil en cas d'échec.
    @discardableResult
    func rebuild(_ app: RemoteApp) async -> String? {
        // État des prompts relu à l'instant : le dernier relevé peut dater.
        await pollRebuild()
        guard !isCompilationBlocked(app) else {
            errorMessage = Self.compilationBlockedMessage(app.name)
            return nil
        }
        do {
            let base = try ServerAddress.parse(address)
            var components = URLComponents(url: base.appending(path: "api/v1/builds"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "app", value: app.id)]
            guard let url = components?.url else { throw ClientError.invalidAddress }
            let data = try await request(url, method: "POST")
            struct Started: Decodable { let id: String }
            let jobID = try JSONDecoder().decode(Started.self, from: data).id
            track(jobID)
            await pollRebuild()
            return jobID
        } catch ClientError.http(409) {
            errorMessage = "Une compilation est déjà en cours sur le Mac."
        } catch ClientError.http(let code) where code == 404 || code == 405 || code == 503 {
            errorMessage = "Compilation impossible (HTTP \(code)) : l’app n’existe plus, ou ServeIPA doit être mis à jour sur le Mac."
        } catch {
            errorMessage = "Compilation impossible : \(error.localizedDescription)"
        }
        return nil
    }

    // MARK: - Messages de réussite

    /// Durée d'affichage d'une réussite (compilation, installation).
    static let successDisplayTime: Duration = .seconds(4)

    func showSuccess(_ message: String) {
        downloadMessage = message
        successMessage = message
        Task { [weak self] in
            try? await Task.sleep(for: Self.successDisplayTime)
            // Un message arrivé entre-temps reste affiché.
            guard let self, downloadMessage == message else { return }
            downloadMessage = nil
            successMessage = nil
        }
    }

    // MARK: - Git

    /// Apps dont le projet est en cours de commit sur le Mac.
    var committingAppIDs: Set<String> = []

    /// Demande au Mac d'indexer et de valider le projet de l'app, puis de pousser si `push`. Le résultat est affiché.
    func commit(_ app: RemoteApp, message: String, push: Bool) async {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            errorMessage = "Commit annulé : le message est vide."
            return
        }
        guard committingAppIDs.insert(app.id).inserted else { return }
        defer { committingAppIDs.remove(app.id) }
        do {
            let base = try ServerAddress.parse(address)
            var components = URLComponents(url: base.appending(path: "api/v1/git"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "app", value: app.id),
                                      URLQueryItem(name: "message", value: message),
                                      URLQueryItem(name: "push", value: push ? "1" : "0")]
            guard let url = components?.url else { throw ClientError.invalidAddress }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            // Le Mac répond une fois git terminé.
            urlRequest.timeoutInterval = 300
            let (data, response) = try await session.data(for: urlRequest)
            struct Answer: Decodable { let message: String?; let error: String? }
            let answer = try? JSONDecoder().decode(Answer.self, from: data)
            if let text = answer?.message ?? answer?.error, (response as? HTTPURLResponse)?.statusCode != 404,
               (response as? HTTPURLResponse)?.statusCode != 405 {
                errorMessage = "\(app.name) : \(text)"
            } else {
                try check(response)
            }
            await refreshNow()
        } catch ClientError.http(let code) where code == 404 || code == 405 || code == 503 {
            errorMessage = "Commit impossible (HTTP \(code)) : ServeIPA doit être mis à jour sur le Mac."
        } catch {
            errorMessage = "Commit : \(error.localizedDescription) Vérifiez l’état du dépôt sur le Mac."
        }
    }

    // MARK: - Lien d'installation serveipa://

    /// Étape en cours d'une installation demandée par lien (nil hors de ce flux).
    private(set) var linkMessage: String?
    /// App concernée (nom demandé, puis nom de l'app trouvée), affichée en titre du suivi.
    private(set) var linkTitle = ""
    private var linkTask: Task<Void, Never>?

    /// Traite `serveipa://install?app=iMetar` (ou `serveipa://install/iMetar`) : installe le dernier build de l'app,
    /// après l'avoir fait recompiler sur le Mac si son projet Xcode a un numéro de build plus récent.
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "serveipa" else { return }
        guard url.host?.lowercased() == "install", let name = Self.linkAppName(url) else {
            errorMessage = "Lien non reconnu. Format attendu : serveipa://install?app=NomDeLApp"
            return
        }
        linkTask?.cancel()
        linkTask = Task { await installFromLink(name: name) }
    }

    func cancelLink() {
        linkTask?.cancel()
        linkTask = nil
        linkMessage = nil
    }

    nonisolated static func linkAppName(_ url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems?.first { $0.name == "app" || $0.name == "name" }?.value
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = (query ?? path).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Dernier build de l'app désignée par son nom (affiché ou de produit), son identifiant de bundle,
    /// ou le dernier composant de celui-ci. Casse, espaces et ponctuation sont ignorés.
    func latestApp(named name: String) -> RemoteApp? {
        let normalize = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let key = normalize(name)
        let latest = AppGroup.grouping(apps).map(\.latest)
        if let exact = latest.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(name) == .orderedSame }) { return exact }
        let fields: [(RemoteApp) -> String] = [
            \.name, \.displayName,
            { String($0.bundleIdentifier.split(separator: ".").last ?? "") }
        ]
        for field in fields {
            if let match = latest.first(where: { normalize(field($0)) == key }) { return match }
        }
        return nil
    }

    private func installFromLink(name: String) async {
        defer { if !Task.isCancelled { linkMessage = nil } }
        linkTitle = name
        linkMessage = "Recherche sur le serveur…"
        await refreshNow()
        guard !Task.isCancelled else { return }
        guard isConnected else {
            errorMessage = "Installation de « \(name) » impossible : \(connectionMessage)"
            return
        }
        guard var app = latestApp(named: name) else {
            errorMessage = "Aucune app « \(name) » sur le serveur."
            return
        }

        linkTitle = app.name
        await pollRebuild()
        // Pendant un prompt, la release disponible est installée sans compiler.
        if let projectBuild = app.projectBuild, !isCompilationBlocked(app) {
            linkMessage = "Recompilation sur le Mac (build \(projectBuild) au lieu de \(app.build))…"
            guard let fresh = await compileOnMac(app, progress: { self.linkMessage = $0 }) else { return }
            app = fresh
        }

        // L'installation OTA doit être confiée à iOS au premier plan.
        while !Platform.isActive {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
        #if os(macOS)
        // Mac : l'app installée est lancée, après avoir quitté son ancienne instance.
        linkMessage = "Installation de \(app.name)…"
        await installMac(app, launches: true)
        linkMessage = nil
        #else
        linkMessage = nil
        await install(app)
        #endif
    }

    /// Fait compiler l'app sur le Mac et attend la release produite. Retourne nil si la compilation échoue, est
    /// annulée ou ne donne rien, et si la tâche est annulée.
    private func compileOnMac(_ app: RemoteApp, progress: (String) -> Void = { _ in }) async -> RemoteApp? {
        guard let jobID = await rebuild(app) else { return nil }
        // Attente de la fin de la compilation ; le Mac interrompt lui-même une compilation bloquée.
        var missing = 0
        waiting: while true {
            do { try await Task.sleep(for: .seconds(2)) } catch { return nil }
            await pollRebuild()
            guard let job = job(jobID) else {
                missing += 1
                if missing >= 60 { errorMessage = "La compilation de \(app.name) ne répond plus."; return nil }
                continue
            }
            missing = 0
            switch job.state {
            case "succeeded": break waiting
            case "failed", "cancelled": return nil // Le résultat reste affiché dans le suivi de compilation.
            default: progress(job.detail)
            }
        }
        // Le Mac signale la fin avant d'avoir réanalysé le dossier des IPA : on attend le nouveau build.
        progress("Attente du nouveau build…")
        for _ in 0..<30 {
            await refreshNow()
            let latest = AppGroup.grouping(apps).first { $0.id == app.bundleIdentifier }?.latest
            if let latest, latest.id != app.id { return latest }
            do { try await Task.sleep(for: .seconds(2)) } catch { return nil }
        }
        errorMessage = "Le nouveau build de \(app.name) n’apparaît pas sur le serveur."
        return nil
    }

    // MARK: - Bouton Installer

    /// Vrai tant qu'une installation demandée attend sa compilation et la nouvelle release.
    func isAwaitingCompiledInstall(_ app: RemoteApp) -> Bool { compilingInstalls.contains(app.bundleIdentifier) }

    /// Vrai si installer ce build passe d'abord par une compilation : dernier build de son app, projet Xcode plus
    /// avancé sur le Mac et aucun prompt rClaude en cours sur ce projet.
    func compilesBeforeInstalling(_ app: RemoteApp) -> Bool {
        guard let projectBuild = app.projectBuild, let build = Int(app.build), projectBuild > build,
              AppGroup.grouping(apps).first(where: { $0.id == app.bundleIdentifier })?.latest.id == app.id,
              !isCompilationBlocked(app) else { return false }
        #if os(macOS)
        // La mise à jour d'un ServeIPA ouvert ici est confiée au serveur, qui le compile lui-même au besoin.
        if isServerApp(app),
           !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty {
            return false
        }
        #endif
        return true
    }

    /// Installation demandée par le bouton : compile d'abord le projet s'il le faut, puis installe la release obtenue.
    /// Sans nouvelle release (échec ou annulation), rien n'est installé.
    func installCompilingIfNeeded(_ app: RemoteApp) async {
        // Une seconde demande pendant la compilation n'installerait pas deux fois.
        guard compilingInstalls.insert(app.bundleIdentifier).inserted else { return }
        defer { compilingInstalls.remove(app.bundleIdentifier) }
        // État des prompts relu à l'instant : le dernier relevé peut dater.
        if app.projectBuild != nil || isOwnApp(app) { await pollRebuild() }
        // Inutile de compiler un client qui ne pourrait pas être installé ensuite.
        if isWaitingForServerUpdate(app) {
            errorMessage = Self.serverUpdatingMessage
            return
        }
        guard compilesBeforeInstalling(app) else {
            await install(app)
            return
        }
        guard let fresh = await compileOnMac(app) else { return }
        // iOS : l'installation doit être demandée au premier plan. Mac : une installation à la fois.
        #if os(macOS)
        while isInstalling {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
        #else
        while !Platform.isActive {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
        #endif
        await install(fresh)
    }

    /// Actualise même si une actualisation est déjà en cours (`refresh` l'ignorerait).
    func refreshNow() async {
        while isLoading {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        await refresh()
    }

    /// Lance la baguette magique sur le Mac : recompile les apps dont le projet est plus récent,
    /// supprime les anciennes versions, copie les releases macOS dans /Applications du Mac, puis commite et pousse
    /// les projets.
    func runServerMaintenance() async {
        do {
            let base = try ServerAddress.parse(address)
            let url = base.appending(path: "api/v1/maintenance").appending(queryItems: [URLQueryItem(name: "git", value: "1")])
            let data = try await request(url, method: "POST")
            struct Started: Decodable { let id: String }
            track(try JSONDecoder().decode(Started.self, from: data).id)
            await pollRebuild()
        } catch ClientError.http(409) {
            errorMessage = "Une compilation est déjà en cours sur le Mac."
        } catch ClientError.http(let code) where code == 404 || code == 405 || code == 503 {
            errorMessage = "Baguette magique indisponible (HTTP \(code)) : ServeIPA doit être mis à jour sur le Mac."
        } catch {
            errorMessage = "Baguette magique impossible : \(error.localizedDescription)"
        }
    }

    // MARK: - Ajout de projets (scan du Mac)

    var remoteProjects: [RemoteProject] = []
    private(set) var isScanningRemote = false
    /// Erreur du dernier scan distant, affichée dans la feuille d'ajout.
    private(set) var remoteScanError: String?

    /// Demande au Mac de scanner son dossier de projets Xcode. Peut durer plusieurs dizaines de secondes.
    func scanRemoteProjects() async {
        guard !isScanningRemote else { return }
        isScanningRemote = true
        remoteScanError = nil
        defer { isScanningRemote = false }
        do {
            let base = try ServerAddress.parse(address)
            var urlRequest = URLRequest(url: base.appending(path: "api/v1/projects"))
            urlRequest.timeoutInterval = 300
            let (data, response) = try await session.data(for: urlRequest)
            try check(response)
            struct Envelope: Decodable { let projects: [RemoteProject]; let error: String? }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            remoteProjects = envelope.projects
            remoteScanError = envelope.error
        } catch ClientError.http(409) {
            remoteScanError = "Une compilation est déjà en cours sur le Mac. Réessayez quand elle sera terminée."
        } catch ClientError.http(let code) where code == 404 || code == 405 || code == 503 {
            remoteScanError = "Scan indisponible (HTTP \(code)) : ServeIPA doit être mis à jour sur le Mac."
        } catch {
            remoteScanError = "Scan impossible : \(error.localizedDescription)"
        }
    }

    func projectKey(_ project: RemoteProject, platform: String) -> String { "\(project.id)|\(platform)" }

    /// Demande au Mac de compiler et d'ajouter un projet trouvé par le scan ; la demande prend place dans sa file.
    /// Retourne le message d'erreur, nil si elle est acceptée.
    func addRemoteProject(_ project: RemoteProject, platform: String) async -> String? {
        await pollRebuild()
        guard !isCompilationBlocked(project) else { return Self.compilationBlockedMessage(project.name) }
        do {
            let base = try ServerAddress.parse(address)
            var components = URLComponents(url: base.appending(path: "api/v1/projects"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "project", value: project.id),
                                      URLQueryItem(name: "platform", value: platform)]
            guard let url = components?.url else { throw ClientError.invalidAddress }
            let data = try await request(url, method: "POST")
            struct Started: Decodable { let id: String }
            let jobID = try JSONDecoder().decode(Started.self, from: data).id
            track(jobID)
            requestedProjects[projectKey(project, platform: platform)] = jobID
            await pollRebuild()
            return nil
        } catch ClientError.http(409) {
            return "Le Mac ne peut pas accepter cette demande pour le moment."
        } catch ClientError.http(404) {
            return "Ce projet n’existe plus dans le dernier scan du Mac. Relancez le scan."
        } catch {
            return "Ajout impossible : \(error.localizedDescription)"
        }
    }

    /// Vrai si le schéma d'URL de l'app est déclaré dans ce client et qu'une app l'ouvre sur cet appareil.
    /// Ne prouve ni l'identité ni la version de l'app installée.
    func isOpenable(_ app: RemoteApp) -> Bool {
        #if os(macOS)
        return installedApp(app) != nil
        #else
        guard let url = app.launchURL, let scheme = url.scheme else { return false }
        let declared = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        return declared.contains(scheme) && Platform.canOpen(url)
        #endif
    }

    func openApp(_ app: RemoteApp) async {
        #if os(macOS)
        if let installed = installedApp(app) { NSWorkspace.shared.open(installed.url) }
        return
        #else
        guard let url = app.launchURL else { return }
        if !(await Platform.open(url)) {
            errorMessage = "Cet appareil ne peut pas ouvrir cette app. Elle est peut-être encore en cours d’installation ou son schéma d’URL ne permet pas son ouverture."
        }
        #endif
    }

    func download(_ app: RemoteApp) {
        guard downloadTask == nil else { return }
        let id = UUID()
        operationID = id
        downloadingAppID = app.id
        downloadedFile = nil
        downloadMessage = "Téléchargement de l’IPA…"
        downloadTask = Task {
            defer {
                if operationID == id {
                    downloadingAppID = nil
                    downloadTask = nil
                }
            }
            do {
                let base = try ServerAddress.parse(address)
                let ticket = try await createTicket(app, server: base)
                let (temporary, response) = try await session.download(from: base.appending(path: ticket.downloadPath))
                try Task.checkCancellation()
                guard operationID == id else { return }
                try check(response)
                let values = try temporary.resourceValues(forKeys: [.fileSizeKey])
                guard Int64(values.fileSize ?? -1) == app.size else { throw ClientError.invalidDownload }
                let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
                    .appending(path: "Downloads", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appending(path: ticket.id + ".ipa")
                try FileManager.default.moveItem(at: temporary, to: destination)
                downloadedFile = destination
                downloadMessage = "IPA reçu (\(ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file))), pas encore installé."
            } catch is CancellationError {
                if operationID == id { downloadMessage = "Téléchargement annulé." }
            } catch {
                if operationID == id {
                    downloadMessage = "Téléchargement échoué."
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// URL de l'icône du build, si le serveur en a une.
    func iconURL(for app: RemoteApp) -> URL? {
        guard app.hasIcon == true, let base = try? ServerAddress.parse(address) else { return nil }
        var components = URLComponents(url: base.appending(path: "api/v1/apps/icon"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "app", value: app.id)]
        return components?.url
    }

    /// Supprime l'IPA du serveur (son dossier d'export sur le Mac), puis recharge la liste.
    func delete(_ app: RemoteApp) async {
        do {
            let base = try ServerAddress.parse(address)
            var components = URLComponents(url: base.appending(path: "api/v1/apps"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "app", value: app.id)]
            guard let url = components?.url else { throw ClientError.invalidAddress }
            _ = try await request(url, method: "DELETE")
            apps.removeAll { $0.id == app.id }
            await refresh()
        } catch ClientError.http(let code) where code == 404 || code == 405 {
            errorMessage = "Suppression impossible (HTTP \(code)) : l’IPA n’existe plus, ou ServeIPA doit être mis à jour sur le Mac."
            await refresh()
        } catch {
            errorMessage = "Suppression impossible : \(error.localizedDescription)"
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadingAppID = nil
        downloadMessage = "Téléchargement annulé."
    }

    func clearPending() {
        pending = nil
        transferCompletedAt = nil
        transfer = nil
        installMessage = nil
        UserDefaults.standard.removeObject(forKey: "pendingInstall")
    }

    private func persistPending() {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: "pendingInstall")
        }
    }

    private func createTicket(_ app: RemoteApp, server: URL) async throws -> InstallTicket {
        var components = URLComponents(url: server.appending(path: "api/v1/sessions"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "app", value: app.id)]
        guard let url = components?.url else { throw ClientError.invalidAddress }
        let data = try await request(url, method: "POST")
        let ticket = try JSONDecoder().decode(InstallTicket.self, from: data)
        try ServerAddress.validate(ticket, server: server)
        return ticket
    }

    func request(_ url: URL, method: String = "GET") async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        try check(response)
        return data
    }

    func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.incompatibleServer }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.http(http.statusCode) }
        guard http.url?.scheme == "https" else { throw ClientError.invalidAddress }
    }
}
