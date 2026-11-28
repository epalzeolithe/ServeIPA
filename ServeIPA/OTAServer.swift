import Foundation
import Network

/// État de la dernière recompilation lancée sur le Mac, exposé par `GET /api/v1/builds`.
nonisolated struct RebuildJob: Codable, Sendable {
    var id: String
    var app: String
    var platform: String
    /// queued, running, succeeded, failed ou cancelled.
    var state: String
    var step: String
    var error: String?
    var startedAt: Date
    /// « rebuild » (une app), « maintenance » (baguette magique : recompilation, nettoyage, copie)
    /// ou « update » (mise à jour de ServeIPA).
    var kind: String = "rebuild"

    var json: [String: Any] {
        var object: [String: Any] = [
            "id": id, "app": app, "platform": platform, "state": state,
            "step": step, "startedAt": startedAt.timeIntervalSince1970, "kind": kind
        ]
        object["error"] = error
        return object
    }
}

/// Résultat d'une demande d'ajout de projet (`POST /api/v1/projects`).
enum ProjectAddResult: Sendable {
    case started(String)
    case busy
    case notFound
}

final class OTAServer: @unchecked Sendable {
    private struct Snapshot {
        /// Builds iOS (IPA), servis par le flux d'installation OTA.
        var buildsByPath: [String: IPABuild] = [:]
        /// Apps macOS (.app), proposées seulement par l'API (`?platform=macOS`) sous forme d'archive zip.
        var macBuildsByPath: [String: IPABuild] = [:]
        var rootURL: URL?
        var publicURL: URL?
    }

    private struct Transfer {
        var sent: Int64
        var total: Int64
        var percent: Int
        var status: String
        var attempt: UUID
    }

    private struct InstallSession {
        let id: String
        let build: IPABuild
        let createdAt: Date
        var sent: Int64 = 0
        var state = "waiting"
    }

    private var sessions: [String: InstallSession] = [:]
    /// Icônes PNG déjà extraites, par identifiant de build.
    private var iconCache: [String: Data] = [:]

    /// Supprime un IPA à la demande d'un client (`DELETE /api/v1/apps?app=…`). Défini avant `start()`.
    var deleteHandler: (@Sendable (IPABuild) async throws -> Void)?
    /// Lance la recompilation d'une app ; retourne l'identifiant du job, ou nil si une compilation est déjà en cours.
    var rebuildHandler: (@Sendable (IPABuild) async -> String?)?
    /// Indexe et valide le projet d'une app, puis pousse au besoin (`POST /api/v1/git?app=…&message=…&push=1`).
    var gitHandler: (@Sendable (IPABuild, String, Bool) async -> GitActionResult)?
    /// Lance la baguette magique (`POST /api/v1/maintenance`) ; retourne l'identifiant du job, ou nil si le Mac est occupé.
    var maintenanceHandler: (@Sendable () async -> String?)?
    /// Scanne le dossier des projets Xcode ; retourne le JSON `{"projects": […]}` (nil si le Mac est occupé).
    var projectsScanHandler: (@Sendable () async -> Data?)?
    /// Compile et ajoute un projet trouvé par le scan (identifiant du projet, plateforme).
    var projectAddHandler: (@Sendable (String, String) async -> ProjectAddResult)?
    /// Met à jour ServeIPA (`POST /api/v1/server/update`) ; retourne l'identifiant du job, ou nil si le Mac est occupé.
    var serverUpdateHandler: (@Sendable () async -> String?)?
    /// Annule un job en attente ou en cours (`DELETE /api/v1/builds?job=…`).
    var cancelHandler: (@Sendable (String) async -> Bool)?
    private var rebuildJob: RebuildJob?
    private var queuedJobs: [RebuildJob] = []
    private var finishedJobs: [RebuildJob] = []
    private var serverUpdateDetail: String?
    private var activePrompts: [String] = []
    /// Numéro de build du projet Xcode, par identifiant de build, quand il dépasse celui de la release.
    private var projectBuilds: [String: Int] = [:]
    /// Change dès que la liste des apps publiée change : les clients la relisent alors sans attendre.
    private var catalogRevision = UUID().uuidString
    private var releaseIDs: Set<String> = []
    private var projectGitDates: [String: ProjectGitDates] = [:]

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ServeIPA.HTTPServer", qos: .userInitiated)
    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var transfers: [String: Transfer] = [:]

    init(port: UInt16) throws {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort
        }
        // Le serveur HTTP n'a pas de TLS ni d'authentification : il ne doit être
        // joignable qu'en loopback. L'exposition externe passe par Tailscale Serve.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: networkPort)
        listener = try NWListener(using: parameters)
    }

    func update(builds: [IPABuild], rootURL: URL, publicURL: URL?) {
        lock.withLock {
            let ids = Set(builds.map(\.id))
            if ids != releaseIDs { catalogRevision = UUID().uuidString }
            releaseIDs = ids
            snapshot = Snapshot(
                buildsByPath: Dictionary(uniqueKeysWithValues: builds.filter { $0.platform == .iOS }.map { ($0.relativePath, $0) }),
                macBuildsByPath: Dictionary(uniqueKeysWithValues: builds.filter { $0.platform == .macOS }.map { ($0.relativePath, $0) }),
                rootURL: rootURL,
                publicURL: publicURL
            )
        }
    }

    func setProjectBuilds(_ builds: [String: Int]) {
        lock.withLock {
            if projectBuilds != builds { catalogRevision = UUID().uuidString }
            projectBuilds = builds
        }
    }

    func setProjectGitDates(_ dates: [String: ProjectGitDates]) {
        lock.withLock {
            if projectGitDates != dates { catalogRevision = UUID().uuidString }
            projectGitDates = dates
        }
    }

    func setRebuildJob(_ job: RebuildJob?) {
        lock.withLock { rebuildJob = job }
    }

    func setJobs(queue: [RebuildJob], history: [RebuildJob]) {
        lock.withLock {
            queuedJobs = queue
            finishedJobs = history
        }
    }

    func setActivePrompts(_ projects: [String]) {
        lock.withLock { activePrompts = projects }
    }

    func setServerUpdate(_ detail: String?) {
        lock.withLock { serverUpdateDetail = detail }
    }

    func start() throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("ServeIPA listener error: \(error)")
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var requestData = accumulated
            if let data {
                requestData.append(data)
            }
            if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(to: requestData, on: connection)
            } else if isComplete || error != nil || requestData.count >= 65_536 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, accumulated: requestData)
            }
        }
    }

    private func respond(to requestData: Data, on connection: NWConnection) {
        guard let request = String(data: requestData, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            send(status: "400 Bad Request", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        let components = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard components.count >= 2 else {
            send(status: "400 Bad Request", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        let method = components[0]
        let target = components[1]
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let encodedPath = String(targetParts.first ?? "/")
        let query = targetParts.count > 1 ? String(targetParts[1]) : ""
        let path = encodedPath.removingPercentEncoding ?? encodedPath
        let current = lock.withLock { snapshot }

        if path.hasPrefix("/api/v1/") {
            respondToAPI(path: path, query: query, method: method, current: current, on: connection)
            return
        }

        guard method == "GET" || method == "HEAD" || (path == "/__reset" && method == "POST") else {
            send(status: "405 Method Not Allowed", body: Data(), contentType: "text/plain", on: connection)
            return
        }

        if path == "/" {
            let body = Self.indexPage(builds: Array(current.buildsByPath.values), publicURL: current.publicURL)
            send(status: "200 OK", body: body, contentType: "text/html; charset=utf-8", method: method, on: connection)
            return
        }

        if path == "/__rescan" {
            send(status: "204 No Content", body: Data(), contentType: "text/plain", method: method, on: connection)
            return
        }

        if path == "/__reset" {
            let file = Self.queryValue("file", in: query) ?? ""
            guard let build = current.buildsByPath[file] else {
                send(status: "404 Not Found", body: Data("Unknown IPA".utf8), contentType: "text/plain", method: method, on: connection)
                return
            }
            lock.withLock {
                transfers[file] = Transfer(
                    sent: 0,
                    total: build.size,
                    percent: 0,
                    status: String(localized: "En attente du téléchargement"),
                    attempt: UUID()
                )
            }
            send(status: "200 OK", body: Data(), contentType: "text/plain", method: method, on: connection)
            return
        }

        if path == "/__progress" {
            let currentTransfers = lock.withLock { transfers }
            var object: [String: Any] = [:]
            for (file, transfer) in currentTransfers {
                object[file] = [
                    "sent": transfer.sent,
                    "total": transfer.total,
                    "percent": transfer.percent,
                    "status": transfer.status
                ]
            }
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            send(status: "200 OK", body: body, contentType: "application/json", method: method, on: connection)
            return
        }

        if path.hasPrefix("/manifest/") {
            let buildPath = String(path.dropFirst("/manifest/".count))
            guard let build = current.buildsByPath[buildPath],
                  let publicURL = current.publicURL,
                  let manifest = Self.manifest(for: build, publicURL: publicURL) else {
                send(status: "404 Not Found", body: Data("Not found".utf8), contentType: "text/plain", method: method, on: connection)
                return
            }
            send(status: "200 OK", body: manifest, contentType: "application/xml", method: method, on: connection)
            return
        }

        let requestedBuildPath = String(path.dropFirst())
        guard let build = current.buildsByPath[requestedBuildPath] else {
            send(status: "404 Not Found", body: Data("Not found".utf8), contentType: "text/plain", method: method, on: connection)
            return
        }
        sendFile(build.fileURL, key: requestedBuildPath, method: method, on: connection)
    }


    // A random session follows the manifest into the IPA URL, isolating concurrent devices.
    private func respondToAPI(path: String, query: String, method: String, current: Snapshot, on connection: NWConnection) {
        if path == "/api/v1/health", method == "GET" {
            let info = AppBuildInfo.current
            var health: [String: Any] = [
                "service": "ServeIPA", "apiVersion": 1,
                "serverVersion": info.version, "serverBuild": info.build
            ]
            health["serverBuildDate"] = AppBuildInfo.rawDate
            health["hostName"] = ProcessInfo.processInfo.hostName
            sendJSON(health, on: connection)
            return
        }
        if path == "/api/v1/apps", method == "GET" {
            let (projectBuilds, gitDates) = lock.withLock { (self.projectBuilds, self.projectGitDates) }
            let wantsMac = Self.queryValue("platform", in: query) == "macOS"
            let apps: [[String: Any]] = (wantsMac ? current.macBuildsByPath : current.buildsByPath).values.sorted {
                ($0.folderDate ?? $0.folderName, $0.name) > ($1.folderDate ?? $1.folderName, $1.name)
            }.map { build in
                var object: [String: Any] = [
                    "id": build.id, "name": build.name, "displayName": build.displayName,
                    "bundleIdentifier": build.bundleIdentifier, "version": build.version,
                    "build": build.build, "size": build.size, "platforms": build.platforms,
                    "urlSchemes": build.urlSchemes,
                    "platform": build.platform.rawValue,
                    "hasIcon": build.iconEntry != nil
                ]
                object["date"] = build.folderDate
                object["minimumOSVersion"] = build.minimumOSVersion
                object["projectBuild"] = projectBuilds[build.id]
                object["builtAt"] = build.builtAt?.timeIntervalSince1970
                object["lastCommit"] = gitDates[build.id]?.lastCommit?.timeIntervalSince1970
                object["lastPush"] = gitDates[build.id]?.lastPush?.timeIntervalSince1970
                object["lastCommitBuild"] = gitDates[build.id]?.commitBuild
                object["lastPushBuild"] = gitDates[build.id]?.pushBuild
                object["isServer"] = build.platform == .macOS && build.bundleIdentifier == Bundle.main.bundleIdentifier
                return object
            }
            sendJSON(["apiVersion": 1, "apps": apps], on: connection)
            return
        }
        if path == "/api/v1/apps/icon", method == "GET" || method == "HEAD" {
            guard let buildID = Self.queryValue("app", in: query),
                  let build = current.buildsByPath[buildID] ?? current.macBuildsByPath[buildID],
                  let entry = build.iconEntry else {
                sendJSON(["error": "Icon unavailable"], status: "404 Not Found", on: connection)
                return
            }
            if let cached = lock.withLock({ iconCache[buildID] }) {
                send(status: "200 OK", body: cached, contentType: "image/png", method: method, on: connection)
                return
            }
            // L'extraction lance unzip : hors de la file du serveur pour ne pas bloquer les autres requêtes.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let png = build.platform == .macOS
                    ? IPAMetadataReader.iconPNG(appURL: build.fileURL, entry: entry)
                    : IPAMetadataReader.iconPNG(ipaURL: build.fileURL, entry: entry)
                guard let png else {
                    self.sendJSON(["error": "Icon unreadable"], status: "404 Not Found", on: connection)
                    return
                }
                self.lock.withLock { self.iconCache[buildID] = png }
                self.send(status: "200 OK", body: png, contentType: "image/png", method: method, on: connection)
            }
            return
        }
        if path == "/api/v1/apps/archive", method == "GET" || method == "HEAD" {
            guard let buildID = Self.queryValue("app", in: query),
                  let build = current.macBuildsByPath[buildID] else {
                sendJSON(["error": "App unavailable"], status: "404 Not Found", on: connection)
                return
            }
            // Le zip d'un bundle .app est créé (puis réutilisé) hors de la file du serveur.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                guard let archive = Self.macArchive(for: build) else {
                    self.sendJSON(["error": "Archive failed"], status: "500 Internal Server Error", on: connection)
                    return
                }
                self.sendFile(archive, key: "archive-\(buildID)", method: method, on: connection)
            }
            return
        }
        if path == "/api/v1/apps", method == "DELETE" {
            guard let buildID = Self.queryValue("app", in: query),
                  let build = current.buildsByPath[buildID] ?? current.macBuildsByPath[buildID] else {
                sendJSON(["error": "App unavailable"], status: "404 Not Found", on: connection)
                return
            }
            guard let deleteHandler else {
                sendJSON(["error": "Deletion unavailable"], status: "503 Service Unavailable", on: connection)
                return
            }
            Task {
                do {
                    try await deleteHandler(build)
                    self.lock.withLock {
                        self.snapshot.buildsByPath[buildID] = nil
                        self.snapshot.macBuildsByPath[buildID] = nil
                    }
                    self.send(status: "204 No Content", body: Data(), contentType: "text/plain", on: connection)
                } catch {
                    self.sendJSON(["error": error.localizedDescription], status: "500 Internal Server Error", on: connection)
                }
            }
            return
        }
        if path == "/api/v1/builds", method == "GET" {
            let (job, queued, finished, update) = lock.withLock {
                (rebuildJob, queuedJobs, finishedJobs, serverUpdateDetail)
            }
            var status: [String: Any] = [
                "apiVersion": 1, "job": job?.json ?? NSNull(),
                "queue": queued.map(\.json), "history": finished.map(\.json)
            ]
            status["serverUpdate"] = update
            status["activePrompts"] = lock.withLock { activePrompts }
            status["catalogRevision"] = lock.withLock { catalogRevision }
            sendJSON(status, on: connection)
            return
        }
        if path == "/api/v1/builds/log", method == "GET" {
            guard let jobID = Self.queryValue("job", in: query), let log = BuildLog.tail(jobID: jobID) else {
                sendJSON(["error": "Log unavailable"], status: "404 Not Found", on: connection)
                return
            }
            send(status: "200 OK", body: log, contentType: "text/plain; charset=utf-8", on: connection)
            return
        }
        if path == "/api/v1/builds", method == "DELETE" {
            guard let jobID = Self.queryValue("job", in: query), let cancelHandler else {
                sendJSON(["error": "Missing job"], status: "400 Bad Request", on: connection)
                return
            }
            Task {
                if await cancelHandler(jobID) {
                    self.sendJSON(["id": jobID], on: connection)
                } else {
                    self.sendJSON(["error": "Job cannot be cancelled"], status: "404 Not Found", on: connection)
                }
            }
            return
        }
        if path == "/api/v1/builds", method == "POST" {
            guard let buildID = Self.queryValue("app", in: query),
                  let build = current.buildsByPath[buildID] ?? current.macBuildsByPath[buildID] else {
                sendJSON(["error": "App unavailable"], status: "404 Not Found", on: connection)
                return
            }
            guard let rebuildHandler else {
                sendJSON(["error": "Rebuild unavailable"], status: "503 Service Unavailable", on: connection)
                return
            }
            Task {
                if let jobID = await rebuildHandler(build) {
                    self.sendJSON(["id": jobID], status: "202 Accepted", on: connection)
                } else {
                    self.sendJSON(["error": "A build is already running"], status: "409 Conflict", on: connection)
                }
            }
            return
        }
        if path == "/api/v1/git", method == "POST" {
            guard let buildID = Self.queryValue("app", in: query),
                  let build = current.buildsByPath[buildID] ?? current.macBuildsByPath[buildID] else {
                sendJSON(["error": "App unavailable"], status: "404 Not Found", on: connection)
                return
            }
            let message = (Self.queryValue("message", in: query) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty, message.count <= 1000 else {
                sendJSON(["error": "Missing or oversized message"], status: "400 Bad Request", on: connection)
                return
            }
            guard let gitHandler else {
                sendJSON(["error": "Git unavailable"], status: "503 Service Unavailable", on: connection)
                return
            }
            let push = Self.queryValue("push", in: query) == "1"
            Task {
                let result = await gitHandler(build, message, push)
                self.sendJSON([result.succeeded ? "message" : "error": result.message],
                              status: result.succeeded ? "200 OK" : "409 Conflict", on: connection)
            }
            return
        }
        if path == "/api/v1/projects", method == "GET" {
            guard let projectsScanHandler else {
                sendJSON(["error": "Scan unavailable"], status: "503 Service Unavailable", on: connection)
                return
            }
            Task {
                if let data = await projectsScanHandler() {
                    self.send(status: "200 OK", body: data, contentType: "application/json; charset=utf-8", on: connection)
                } else {
                    self.sendJSON(["error": "A build is already running"], status: "409 Conflict", on: connection)
                }
            }
            return
        }
        if path == "/api/v1/projects", method == "POST" {
            guard let projectID = Self.queryValue("project", in: query),
                  let platform = Self.queryValue("platform", in: query) else {
                sendJSON(["error": "Missing project or platform"], status: "400 Bad Request", on: connection)
                return
            }
            guard let projectAddHandler else {
                sendJSON(["error": "Project add unavailable"], status: "503 Service Unavailable", on: connection)
                return
            }
            Task {
                switch await projectAddHandler(projectID, platform) {
                case .started(let jobID): self.sendJSON(["id": jobID], status: "202 Accepted", on: connection)
                case .busy: self.sendJSON(["error": "A build is already running"], status: "409 Conflict", on: connection)
                case .notFound: self.sendJSON(["error": "Project unavailable"], status: "404 Not Found", on: connection)
                }
            }
            return
        }
        if path == "/api/v1/server/update", method == "POST" {
            guard let serverUpdateHandler else {
                sendJSON(["error": "Update unavailable"], status: "503 Service Unavailable", on: connection)
                return
            }
            Task {
                if let jobID = await serverUpdateHandler() {
                    self.sendJSON(["id": jobID], status: "202 Accepted", on: connection)
                } else {
                    self.sendJSON(["error": "A build is already running"], status: "409 Conflict", on: connection)
                }
            }
            return
        }
        if path == "/api/v1/maintenance", method == "POST" {
            guard let maintenanceHandler else {
                sendJSON(["error": "Maintenance unavailable"], status: "503 Service Unavailable", on: connection)
                return
            }
            Task {
                if let jobID = await maintenanceHandler() {
                    self.sendJSON(["id": jobID], status: "202 Accepted", on: connection)
                } else {
                    self.sendJSON(["error": "A build is already running"], status: "409 Conflict", on: connection)
                }
            }
            return
        }
        if path == "/api/v1/sessions", method == "POST" {
            guard let buildID = Self.queryValue("app", in: query),
                  let build = current.buildsByPath[buildID], let publicURL = current.publicURL else {
                sendJSON(["error": "App unavailable"], status: "404 Not Found", on: connection)
                return
            }
            let id = UUID().uuidString
            let accepted = lock.withLock {
                sessions = sessions.filter { Date().timeIntervalSince($0.value.createdAt) < 86_400 }
                guard sessions.count < 1000 else { return false }
                sessions[id] = InstallSession(id: id, build: build, createdAt: Date())
                return true
            }
            guard accepted else {
                sendJSON(["error": "Too many sessions"], status: "503 Service Unavailable", on: connection)
                return
            }
            let manifestURL = publicURL.appending(path: "api/v1/sessions/\(id)/manifest").absoluteString
            var install = URLComponents()
            install.scheme = "itms-services"
            install.host = ""
            install.queryItems = [
                URLQueryItem(name: "action", value: "download-manifest"),
                URLQueryItem(name: "url", value: manifestURL)
            ]
            sendJSON([
                "id": id,
                "installURL": install.url?.absoluteString ?? "",
                "downloadPath": "api/v1/sessions/\(id)/ipa"
            ], status: "201 Created", on: connection)
            return
        }
        let parts = path.split(separator: "/")
        guard parts.count >= 4, parts[2] == "sessions",
              let session = lock.withLock({ sessions[String(parts[3])] }),
              Date().timeIntervalSince(session.createdAt) < 86_400 else {
            sendJSON(["error": "Session expired or unknown"], status: "404 Not Found", on: connection)
            return
        }
        if parts.count == 4, method == "GET" {
            sendJSON([
                "id": session.id, "sent": session.sent, "total": session.build.size,
                "state": session.state
            ], on: connection)
        } else if parts.count == 5, parts[4] == "manifest", method == "GET",
                  let publicURL = current.publicURL {
            let ipaURL = publicURL.appending(path: "api/v1/sessions/\(session.id)/ipa")
            guard let body = Self.manifest(for: session.build, publicURL: publicURL, downloadURL: ipaURL) else {
                sendJSON(["error": "Invalid manifest"], status: "500 Internal Server Error", on: connection)
                return
            }
            send(status: "200 OK", body: body, contentType: "application/xml", on: connection)
        } else if parts.count == 5, parts[4] == "ipa", method == "GET" || method == "HEAD" {
            sendFile(session.build.fileURL, key: session.id, method: method, on: connection)
        } else {
            sendJSON(["error": "Unsupported endpoint or method"], status: "405 Method Not Allowed", on: connection)
        }
    }

    private func sendJSON(_ object: [String: Any], status: String = "200 OK", on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            send(status: "500 Internal Server Error", body: Data(), contentType: "application/json", on: connection)
            return
        }
        send(status: status, body: data, contentType: "application/json; charset=utf-8", on: connection)
    }

    /// Zip du bundle .app (ditto conserve liens et signature), mis en cache dans le dossier temporaire.
    private nonisolated static func macArchive(for build: IPABuild) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ServeIPA-archives", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(build.id.unicodeScalars.map { $0.properties.isAlphabetic || ("0"..."9").contains($0) ? Character($0) : "_" })
        let archive = directory.appending(path: name + ".zip")
        if FileManager.default.fileExists(atPath: archive.path) { return archive }
        let partial = directory.appending(path: name + ".partial")
        try? FileManager.default.removeItem(at: partial)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", build.fileURL.path, partial.path]
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              (try? FileManager.default.moveItem(at: partial, to: archive)) != nil else {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        return archive
    }

    private static func queryValue(_ name: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            guard keyValue.count == 2, keyValue[0] == name else { continue }
            return String(keyValue[1]).removingPercentEncoding
        }
        return nil
    }

    private func send(
        status: String,
        body: Data,
        contentType: String,
        method: String = "GET",
        on connection: NWConnection
    ) {
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        if method != "HEAD" {
            response.append(body)
        }
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendFile(_ url: URL, key: String, method: String, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            send(status: "404 Not Found", body: Data(), contentType: "text/plain", method: method, on: connection)
            return
        }
        let total = size.int64Value
        if method != "HEAD" {
            lock.withLock {
                sessions[key]?.state = "transferring"
                sessions[key]?.sent = 0
            }
        }

        let attempt: UUID = lock.withLock {
            let existing = transfers[key]?.attempt ?? UUID()
            transfers[key] = Transfer(
                sent: 0,
                total: total,
                percent: 0,
                status: String(localized: "Téléchargement en cours"),
                attempt: existing
            )
            return existing
        }

        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: application/octet-stream\r
        Content-Length: \(total)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, method != "HEAD" else {
                try? handle.close()
                connection.cancel()
                return
            }
            self?.sendNextChunk(from: handle, key: key, attempt: attempt, sent: 0, total: total, on: connection)
        })
    }

    private func sendNextChunk(
        from handle: FileHandle,
        key: String,
        attempt: UUID,
        sent: Int64,
        total: Int64,
        on connection: NWConnection
    ) {
        do {
            let chunk = try handle.read(upToCount: 65_536) ?? Data()
            guard !chunk.isEmpty else {
                try handle.close()
                lock.withLock {
                    if transfers[key]?.attempt == attempt {
                        transfers[key]?.status = String(localized: "Transfert HTTP terminé (installation non confirmée)")
                        sessions[key]?.state = sent == total ? "transferred" : "failed"
                        sessions[key]?.sent = sent
                    }
                }
                connection.cancel()
                return
            }
            let newSent = sent + Int64(chunk.count)
            let percent = total > 0 ? Int(newSent * 100 / total) : 100
            lock.withLock {
                if transfers[key]?.attempt == attempt {
                    transfers[key]?.sent = newSent
                    transfers[key]?.percent = percent
                }
            }
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                if error == nil {
                    self?.lock.withLock {
                        self?.sessions[key]?.sent = newSent
                    }
                    self?.sendNextChunk(from: handle, key: key, attempt: attempt, sent: newSent, total: total, on: connection)
                } else {
                    try? handle.close()
                    self?.lock.withLock {
                        if self?.transfers[key]?.attempt == attempt {
                            self?.transfers[key]?.status = String(localized: "Connexion interrompue")
                            self?.sessions[key]?.state = "failed"
                        }
                    }
                    connection.cancel()
                }
            })
        } catch {
            lock.withLock { sessions[key]?.state = "failed" }
            try? handle.close()
            connection.cancel()
        }
    }

    private static func manifest(for build: IPABuild, publicURL: URL, downloadURL: URL? = nil) -> Data? {
        let ipaURL = (downloadURL ?? publicURL.appending(path: build.relativePath)).absoluteString
        let object: [String: Any] = [
            "items": [[
                "assets": [["kind": "software-package", "url": ipaURL]],
                "metadata": [
                    "bundle-identifier": build.bundleIdentifier,
                    "bundle-version": build.build,
                    "kind": "software",
                    "title": build.name
                ]
            ]]
        ]
        return try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    private static func indexPage(builds: [IPABuild], publicURL: URL?) -> Data {
        let cards = builds.sorted {
            ($0.folderDate ?? $0.folderName, $0.name) > ($1.folderDate ?? $1.folderName, $1.name)
        }.map { build in
            let manifestPath = "manifest/" + build.relativePath
            let manifestURL = publicURL?.appending(path: manifestPath).absoluteString ?? ""
            let installURL = "itms-services://?action=download-manifest&url=" + urlEncode(manifestURL)
            let version = build.version.isEmpty ? "—" : escape(build.version)
            let filePath = escape(build.relativePath)
            return """
            <article class="card" data-file="\(filePath)"><h2>\(escape(build.displayName))</h2>
            <div class="date">\(escape(build.folderDate ?? build.folderName))</div>
            <p>\(escape(build.name)) · \(escape(build.bundleIdentifier))</p>
            <p>Version \(version) · Build \(escape(build.build)) · \(String(format: "%.1f", Double(build.size) / 1_048_576)) Mo</p>
            <a class="install" href="\(escape(installURL))" onclick="return install(event,this)">Installer sur cet appareil</a>
            <progress max="100" value="0"></progress><div class="state">En attente</div>
            </article>
            """
        }.joined()

        let empty = cards.isEmpty ? "<p>Aucun IPA trouvé dans les sous-dossiers.</p>" : ""
        let html = """
        <!doctype html><html lang="fr"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>ServeIPA</title>
        <style>
        *{box-sizing:border-box}body{margin:0;background:#f5f5f7;color:#1d1d1f;font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:20px}
        main{max-width:720px;margin:auto}.card{background:white;border-radius:17px;padding:22px;margin:16px 0;box-shadow:0 2px 14px #0000000a}
        h1{font-size:29px}h2{margin:0 0 6px}.date{color:#007aff;font-weight:600}p,.state{color:#666;font-size:14px}
        .install{display:block;background:#007aff;color:white;text-decoration:none;text-align:center;border-radius:11px;padding:15px;margin:18px 0;font-weight:600}
        progress{width:100%;height:18px}.state{margin-top:8px}
        </style></head><body><main><h1>ServeIPA</h1><p>Choisissez une version à installer sur cet iPhone ou iPad.</p>\(empty)\(cards)</main>
        <script>
        async function install(event,link){
         event.preventDefault();const card=link.closest('.card'),file=card.dataset.file;
         card.querySelector('progress').value=0;
         card.querySelector('.state').textContent='Nouvelle tentative : attente du téléchargement (0 %)';
         try{const r=await fetch('/__reset?file='+encodeURIComponent(file),{method:'POST',cache:'no-store'});
         if(!r.ok)throw Error('HTTP '+r.status);window.location.href=link.href;
         }catch(e){card.querySelector('.state').textContent='Erreur : '+e.message;}
         return false;
        }
        async function update(){try{const r=await fetch('/__progress',{cache:'no-store'});if(!r.ok)return;
         const data=await r.json();document.querySelectorAll('.card').forEach(card=>{
         const t=data[card.dataset.file];if(!t)return;
         card.querySelector('progress').value=t.percent;
         card.querySelector('.state').textContent=t.status+' — '+t.percent+' % ('+(t.sent/1048576).toFixed(1)+' / '+(t.total/1048576).toFixed(1)+' Mo)';
         });}catch(e){}}
        update();setInterval(update,1000);
        </script></body></html>
        """
        return Data(html.utf8)
    }

    private static func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?&=#"))) ?? value
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    enum ServerError: LocalizedError {
        case invalidPort

        var errorDescription: String? {
            String(localized: "Port serveur invalide.")
        }
    }
}
