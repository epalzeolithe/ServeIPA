import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ClientStore {
    var address = UserDefaults.standard.string(forKey: "serverAddress") ?? ServerAddress.defaultValue
    var autoOpen = UserDefaults.standard.bool(forKey: "autoOpen") {
        didSet { UserDefaults.standard.set(autoOpen, forKey: "autoOpen") }
    }
    var apps: [RemoteApp] = []
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
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let requestedAddress = address
        do {
            let base = try ServerAddress.parse(requestedAddress)
            let data = try await request(base.appending(path: "api/v1/health"))
            struct Health: Decodable { let service: String; let apiVersion: Int }
            guard let health = try? JSONDecoder().decode(Health.self, from: data),
                  health.service == "ServeIPA", health.apiVersion == 1 else {
                throw ClientError.incompatibleServer
            }
            let catalogData = try await request(base.appending(path: "api/v1/apps"))
            let catalog = try JSONDecoder().decode(AppCatalog.self, from: catalogData)
            guard catalog.apiVersion == 1 else { throw ClientError.incompatibleServer }
            guard address == requestedAddress else { return }
            apps = catalog.apps
            isConnected = true
            connectionMessage = base.host?.hasSuffix(".ts.net") == true
                ? "Serveur Tailscale accessible" : "Serveur accessible"
        } catch {
            guard address == requestedAddress else { return }
            isConnected = false
            apps = []
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
            await pollInstallation()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func install(_ app: RemoteApp) async {
        do {
            let base = try ServerAddress.parse(address)
            let ticket = try await createTicket(app, server: base)
            let launchURL = app.launchURL
            let declared = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
            let supported = launchURL.map { declared.contains($0.scheme ?? "") } ?? false
            let detected = supported && launchURL.map { UIApplication.shared.canOpenURL($0) } == true
            pending = PendingInstall(app: app, ticket: ticket, server: base, createdAt: Date(),
                                     wasDetectable: detected, detectionSupported: supported)
            transfer = nil
            installMessage = "Demande envoyée à iOS. Confirmez l’installation, puis revenez ici pour le suivi."
            persistPending()
            guard await UIApplication.shared.open(ticket.installURL) else {
                clearPending()
                throw ClientError.invalidLink
            }
        } catch { errorMessage = error.localizedDescription }
    }

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
               let url = pending.app.launchURL, UIApplication.shared.canOpenURL(url) {
                installMessage = "L’app est maintenant ouvrable. La version installée n’est pas vérifiable."
                if autoOpen, !pending.didAutoOpen, progress.state == "transferred",
                   UIApplication.shared.applicationState == .active {
                    pending.didAutoOpen = true
                    self.pending = pending
                    persistPending()
                    _ = await UIApplication.shared.open(url)
                }
            }
        } catch {
            guard self.pending?.ticket.id == pending.ticket.id else { return }
            installMessage = "Suivi indisponible : \(error.localizedDescription)"
        }
    }

    func openApp(_ app: RemoteApp) async {
        guard let url = app.launchURL else { return }
        if !(await UIApplication.shared.open(url)) {
            errorMessage = "iOS ne peut pas ouvrir cette app. Elle est peut-être encore en cours d’installation ou son schéma d’URL ne permet pas son ouverture."
        }
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
