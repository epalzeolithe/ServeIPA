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
    var isLoading = false
    var errorMessage: String?
    var pending: PendingInstall?
    var transfer: TransferProgress?
    var installMessage: String?
    var downloadedFile: URL?
    var downloadingAppID: String?
    var downloadMessage: String?
    /// Apps installées dans Applications (macOS), par identifiant de bundle ; relues à chaque actualisation.
    #if os(macOS)
    private(set) var installedApps: [String: InstalledApp] = [:]
    #endif
    /// Dernière recompilation connue côté Mac, et celle lancée depuis ce client (affichée jusqu'à sa fermeture).
    private(set) var rebuildJob: RebuildJob?
    private var ownedJobID: String?
    private var dismissedJobID: String?
    private var downloadTask: Task<Void, Never>?
    private var operationID = UUID()

    private let session: URLSession = {
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
            isConnected = true
            connectionMessage = base.host?.hasSuffix(".ts.net") == true
                ? "Serveur Tailscale accessible" : "Serveur accessible"
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
        }
    }

    func monitor() async {
        await refresh()
        while !Task.isCancelled {
            await pollRebuild()
            await pollInstallation()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func install(_ app: RemoteApp) async {
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
            pending = PendingInstall(app: app, ticket: ticket, server: base, createdAt: Date(),
                                     wasDetectable: detected, detectionSupported: supported)
            transfer = nil
            installMessage = "Demande envoyée à iOS. Confirmez l’installation, puis revenez ici pour le suivi."
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

    /// Télécharge l'archive de l'app, la décompresse et la place dans /Applications (en remplaçant la version présente).
    /// Retourne nil en cas de succès, sinon le message d'erreur (affiché dans une alerte si `reportsError`).
    @discardableResult
    func installMac(_ app: RemoteApp, reportsError: Bool = true) async -> String? {
        guard downloadTask == nil else { return nil }
        let id = UUID()
        operationID = id
        downloadingAppID = app.id
        downloadedFile = nil
        downloadMessage = "Téléchargement de \(app.name)…"
        defer { if operationID == id { downloadingAppID = nil } }
        do {
            let base = try ServerAddress.parse(address)
            var components = URLComponents(url: base.appending(path: "api/v1/apps/archive"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "app", value: app.id)]
            guard let url = components?.url else { throw ClientError.invalidAddress }
            let (archive, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: archive) }
            try check(response)
            downloadMessage = "Installation de \(app.name) dans Applications…"
            let installed = try await Self.install(archive: archive, bundleIdentifier: app.bundleIdentifier)
            await reloadInstalledApps()
            downloadedFile = installed
            downloadMessage = "\(installed.lastPathComponent) \(app.version) (\(app.build)) est installée dans Applications."
            return nil
        } catch {
            downloadMessage = "Installation échouée."
            if reportsError { errorMessage = error.localizedDescription }
            return error.localizedDescription
        }
    }

    /// Dernier build de chaque app installée dont la version installée est plus ancienne que celle du serveur.
    var outdatedInstalledApps: [RemoteApp] {
        AppGroup.grouping(apps).map(\.latest).filter { installedApp($0)?.record.isOlder(than: $0) == true }
    }

    /// Avancement de la mise à jour groupée : app en cours (0-based) sur le total.
    private(set) var updateBatch: (index: Int, total: Int)?

    /// Télécharge et installe, l'une après l'autre, toutes les apps installées qui ont un build plus récent sur le serveur.
    func updateInstalledApps() async {
        guard updateBatch == nil, downloadTask == nil else { return }
        let targets = outdatedInstalledApps
        guard !targets.isEmpty else { return }
        var failures: [String] = []
        for (index, app) in targets.enumerated() {
            updateBatch = (index, targets.count)
            if let error = await installMac(app, reportsError: false) { failures.append("\(app.name) : \(error)") }
        }
        updateBatch = nil
        let done = targets.count - failures.count
        downloadMessage = failures.isEmpty
            ? "\(done) app(s) mise(s) à jour dans Applications."
            : "\(done) mise(s) à jour, \(failures.count) échec(s)."
        if !failures.isEmpty {
            downloadedFile = nil
            errorMessage = failures.joined(separator: "\n")
        }
    }

    /// Décompresse l'archive puis remplace l'app de /Applications. Hors du thread principal (ditto, copie).
    nonisolated private static func install(archive: URL, bundleIdentifier: String) async throws -> URL {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appending(path: "ServeIPAClient-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, work.path]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0,
              let name = try fileManager.contentsOfDirectory(atPath: work.path).first(where: { $0.hasSuffix(".app") }) else {
            throw ClientError.invalidDownload
        }
        let extracted = work.appending(path: name, directoryHint: .isDirectory)
        // On n'installe que l'app annoncée par le serveur.
        guard Bundle(url: extracted)?.bundleIdentifier == bundleIdentifier else { throw ClientError.invalidDownload }
        let destination = applicationsFolder.appending(path: name, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: extracted)
        } else {
            try fileManager.moveItem(at: extracted, to: destination)
        }
        return destination
    }

    struct InstalledApp: Sendable {
        let url: URL
        let version: String
        let build: String
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
                guard let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let identifier = info["CFBundleIdentifier"] as? String,
                      let build = info["CFBundleVersion"] as? String else { continue }
                // En cas de doublon, /Applications (lu en premier) l'emporte.
                if found[identifier] == nil {
                    found[identifier] = InstalledApp(url: url, version: info["CFBundleShortVersionString"] as? String ?? "", build: build)
                }
            }
        }
        return found
    }

    /// Version réellement installée sur ce Mac.
    func installedApp(_ app: RemoteApp) -> (url: URL, record: InstallRecord)? {
        guard let installed = installedApps[app.bundleIdentifier] else { return nil }
        return (installed.url, InstallRecord(appID: "", version: installed.version, build: installed.build, date: Date()))
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
                installMessage = "IPA transmis par le Mac. iOS ne confirme pas la fin de l’installation."
            case "transferring":
                installMessage = "Transfert de l’IPA vers iOS…"
            case "failed":
                installMessage = "Transfert interrompu. Relancez l’installation."
            default:
                installMessage = "En attente du téléchargement par iOS. Vérifiez la confirmation d’installation."
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
        } catch {
            guard self.pending?.ticket.id == pending.ticket.id else { return }
            installMessage = "Suivi indisponible : \(error.localizedDescription)"
        }
    }

    /// Compilation à afficher : en cours (quel qu'en soit l'initiateur) ou terminée si lancée ici et non fermée.
    var visibleRebuild: RebuildJob? {
        guard let job = rebuildJob else { return nil }
        if job.state == "running" { return job }
        return job.id == ownedJobID && job.id != dismissedJobID ? job : nil
    }

    /// Demande au Mac de recompiler l'app (même plateforme que ce build).
    func rebuild(_ app: RemoteApp) async {
        do {
            let base = try ServerAddress.parse(address)
            var components = URLComponents(url: base.appending(path: "api/v1/builds"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "app", value: app.id)]
            guard let url = components?.url else { throw ClientError.invalidAddress }
            let data = try await request(url, method: "POST")
            struct Started: Decodable { let id: String }
            ownedJobID = try JSONDecoder().decode(Started.self, from: data).id
            await pollRebuild()
        } catch ClientError.http(409) {
            errorMessage = "Une compilation est déjà en cours sur le Mac."
        } catch ClientError.http(let code) where code == 404 || code == 405 || code == 503 {
            errorMessage = "Compilation impossible (HTTP \(code)) : l’app n’existe plus, ou ServeIPA doit être mis à jour sur le Mac."
        } catch {
            errorMessage = "Compilation impossible : \(error.localizedDescription)"
        }
    }

    func dismissRebuild() { dismissedJobID = rebuildJob?.id }

    func pollRebuild() async {
        guard isConnected, let base = try? ServerAddress.parse(address) else { return }
        struct Envelope: Decodable { let job: RebuildJob? }
        guard let data = try? await request(base.appending(path: "api/v1/builds")),
              let job = (try? JSONDecoder().decode(Envelope.self, from: data))?.job else {
            rebuildJob = nil
            return
        }
        let finished = rebuildJob?.id == job.id && rebuildJob?.state == "running" && job.state == "succeeded"
        rebuildJob = job
        // Le nouveau build vient d'apparaître sur le Mac : on recharge la liste.
        if finished { await refresh() }
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
        downloadMessage = "Téléchargement du fichier IPA…"
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
                downloadMessage = "IPA reçu et enregistré (\(ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file))). Ce fichier n’est pas encore installé."
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

    private func request(_ url: URL, method: String = "GET") async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let (data, response) = try await session.data(for: request)
        try check(response)
        return data
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.incompatibleServer }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.http(http.statusCode) }
        guard http.url?.scheme == "https" else { throw ClientError.invalidAddress }
    }
}
