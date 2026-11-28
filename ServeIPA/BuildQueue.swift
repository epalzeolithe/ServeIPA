import Foundation

/// Journal d'une compilation, conservé dans ~/Library/Logs/ServeIPA/builds pour être lu depuis un client.
nonisolated enum BuildLog {
    /// Nombre de journaux conservés.
    private static let kept = 30
    /// Taille maximale transmise à un client (fin du journal).
    private static let maximumTail: UInt64 = 200_000

    static var directory: URL {
        URL.libraryDirectory.appending(path: "Logs/ServeIPA/builds", directoryHint: .isDirectory)
    }

    /// Nil si l'identifiant n'est pas un UUID : il vient d'un client et sert à former un nom de fichier.
    static func url(jobID: String) -> URL? {
        guard let id = UUID(uuidString: jobID) else { return nil }
        return directory.appending(path: "\(id.uuidString).log")
    }

    static func append(_ text: String, to url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
            prune()
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((text + "\n").utf8))
    }

    static func tail(jobID: String) -> Data? {
        guard let url = url(jobID: jobID), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > maximumTail ? size - maximumTail : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        // La coupure peut tomber au milieu d'un caractère : le décodage tolérant évite un journal illisible.
        return Data(String(decoding: data, as: UTF8.self).utf8)
    }

    private static func prune() {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let date = { (url: URL) in
            (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
        }
        for file in files.sorted(by: { date($0) > date($1) }).dropFirst(kept) {
            try? manager.removeItem(at: file)
        }
    }
}

/// Demande d'un client en attente de son tour.
struct QueuedJob {
    var job: RebuildJob
    /// Deux demandes de même clé désignent le même travail.
    let key: String
    let run: @MainActor (_ jobID: String) async -> Void
}

// MARK: - File d'attente, annulation et historique

extension IPAStore {
    private static let maximumQueue = 50
    private static let maximumHistory = 20

    /// Vrai tant qu'un travail (local ou distant) occupe le Mac.
    var isBusy: Bool {
        rebuildingBundleID != nil || isAddingProjects || isRunningMaintenance || isScanningProjects
    }

    /// Place une demande dans la file et retourne son identifiant ; celui de la demande identique déjà présente
    /// le cas échéant. Nil si elle ne peut pas être acceptée.
    func enqueue(app: String, platform: String, kind: String, key: String,
                 run: @escaping @MainActor (_ jobID: String) async -> Void) -> String? {
        guard folderURL != nil, !isInstallingUpdate else { return nil }
        if let waiting = pendingJobs.first(where: { $0.key == key }) { return waiting.job.id }
        if runningQueueKey == key, let currentJob, currentJob.state == "running" { return currentJob.id }
        guard pendingJobs.count < Self.maximumQueue else { return nil }
        let job = RebuildJob(id: UUID().uuidString, app: app, platform: platform, state: "queued",
                             step: String(localized: "En file d’attente"), error: nil, startedAt: Date(), kind: kind)
        pendingJobs.append(QueuedJob(job: job, key: key, run: run))
        publishJobs()
        processQueue()
        return job.id
    }

    private func processQueue() {
        guard queueTask == nil else { return }
        queueTask = Task {
            while !pendingJobs.isEmpty {
                if isBusy || isInstallingUpdate {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                // La mise à jour de ServeIPA le relance et viderait la file : elle passe en dernier.
                let index = pendingJobs.firstIndex { $0.job.kind != "update" } ?? 0
                let next = pendingJobs.remove(at: index)
                runningQueueKey = next.key
                publishJobs()
                // Aucune suspension depuis le test `isBusy` : le travail réserve le Mac avant tout autre.
                await next.run(next.job.id)
                runningQueueKey = nil
            }
            queueTask = nil
        }
    }

    /// Annule une demande en attente ou la compilation en cours. Faux si elle est terminée, inconnue,
    /// ou déjà en phase d'installation.
    func cancelJob(_ id: String) -> Bool {
        if let index = pendingJobs.firstIndex(where: { $0.job.id == id }) {
            var job = pendingJobs.remove(at: index).job
            job.state = "cancelled"
            job.step = String(localized: "Annulée")
            record(job)
            return true
        }
        guard let currentJob, currentJob.id == id, currentJob.state == "running", !isInstallingUpdate else { return false }
        cancelledJobID = id
        activeBuild?.cancel()
        updateJob { $0.step = String(localized: "Annulation…") }
        return true
    }

    /// Publie un nouveau job comme job courant.
    func beginJob(_ job: RebuildJob) {
        currentJob = job
        server?.setRebuildJob(job)
    }

    /// Ajoute un job terminé à l'historique (conservé d'un lancement à l'autre).
    func record(_ job: RebuildJob) {
        jobHistory.removeAll { $0.id == job.id }
        jobHistory.insert(job, at: 0)
        jobHistory = Array(jobHistory.prefix(Self.maximumHistory))
        if let data = try? JSONEncoder().encode(jobHistory) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.jobHistory)
        }
        publishJobs()
    }

    func publishJobs() {
        server?.setJobs(queue: pendingJobs.map(\.job), history: jobHistory)
    }
}

// MARK: - Mise à jour de ServeIPA

/// Ce que ferait une mise à jour de ServeIPA maintenant.
enum SelfUpdatePlan: Sendable {
    case upToDate(running: Int)
    /// Release déjà exportée, correspondant aux sources.
    case install(export: URL, build: String)
    case compile(project: URL, reason: String)
}

/// Mise à jour confiée au script d'installation, relue au lancement suivant.
private struct PendingUpdate: Codable {
    let jobID: String
    let build: String
}

extension IPAStore {
    /// `reusesLocation` : la détection périodique se contente de l'emplacement retenu du projet ; une mise à jour
    /// le recherche à nouveau.
    func selfUpdatePlan(reusesLocation: Bool = false) async throws -> SelfUpdatePlan {
        guard let folderURL, let devRoot = effectiveProjectsFolder else {
            throw IPARebuilder.RebuildError.unreadableFolder("—")
        }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let running = Int(AppBuildInfo.current.build) ?? 0
        let (project, projectNumber, recorded, changed) = try await Task.detached {
            let known = reusesLocation ? ProjectLocator.find(bundleIdentifier: bundleID, appName: "ServeIPA",
                                                            devRoot: devRoot, ipaRoot: folderURL) : nil
            let project = try known ?? IPARebuilder.findProject(bundleIdentifier: bundleID, appName: "ServeIPA",
                                                                devRoot: devRoot, ipaRoot: folderURL)
            let folder = project.deletingLastPathComponent()
            return (project, ProjectBuildNumber.read(project: project) ?? 0, ProjectBuildNumber.recorded(in: folder),
                    SelfUpdater.sourcesChanged(in: folder))
        }.value
        let number = { (build: IPABuild) in Int(build.build) ?? 0 }
        // Release déjà exportée, plus récente que l'app en cours et au moins au niveau du projet.
        let release = changed ? nil : builds
            .filter { $0.platform == .macOS && $0.bundleIdentifier == bundleID }
            .filter { number($0) > running && number($0) >= projectNumber }
            .max { number($0) < number($1) }
        if let release {
            return .install(export: release.fileURL.deletingLastPathComponent(), build: release.build)
        }
        if changed {
            // La prochaine compilation prendra le numéro suivant celui inscrit.
            let reason = if let recorded {
                String(localized: "Build \(recorded + 1) à compiler (sources modifiées), serveur au build \(running).")
            } else {
                String(localized: "Sources à compiler (numéro de build inconnu), serveur au build \(running).")
            }
            return .compile(project: project, reason: reason)
        }
        if projectNumber > running {
            return .compile(project: project,
                            reason: String(localized: "Build \(projectNumber) à compiler, serveur au build \(running)."))
        }
        return .upToDate(running: running)
    }

    /// Recalcule la mise à jour disponible, signalée aux clients.
    func checkForServerUpdate() async {
        guard !isBusy, !isInstallingUpdate else { return }
        let detail: String? = switch try? await selfUpdatePlan(reusesLocation: true) {
        case .install(_, let build): String(localized: "Build \(build) prêt à installer.")
        case .compile(_, let reason): reason
        case .upToDate, nil: nil
        }
        serverUpdateDetail = detail
        server?.setServerUpdate(detail)
    }

    /// Mise à jour demandée par un client distant, sans confirmation sur le Mac.
    func runRemoteServerUpdate(jobID: String) async {
        rebuildingBundleID = "ServeIPA"
        rebuildError = nil
        beginJob(RebuildJob(id: jobID, app: "ServeIPA", platform: IPABuild.Platform.macOS.rawValue, state: "running",
                            step: String(localized: "Vérification de la version…"), error: nil, startedAt: Date(),
                            kind: "update"))
        defer {
            rebuildingBundleID = nil
            rebuildStatus = nil
        }
        do {
            await refresh()
            let export: URL
            switch try await selfUpdatePlan() {
            case .upToDate(let running):
                updateJob {
                    $0.state = "succeeded"
                    $0.step = String(localized: "ServeIPA est déjà à jour (build \(running)).")
                }
                return
            case .install(let folder, _):
                export = folder
            case .compile(let project, _):
                export = try await compileServeIPA(project: project, jobID: jobID)
            }
            guard cancelledJobID != jobID else { throw CancellationError() }
            let app = try SelfUpdater.exportedApp(in: export)
            showUpdateStep(String(localized: "Installation et relance…"))
            isInstallingUpdate = true
            // Laisse au client le temps de lire cette étape avant l'arrêt du serveur.
            try? await Task.sleep(for: .seconds(3))
            try await relaunch(with: app, to: SelfUpdater.installLocation, jobID: jobID, mustServe: true)
        } catch {
            isInstallingUpdate = false
            let cancelled = cancelledJobID == jobID
            updateJob {
                $0.state = cancelled ? "cancelled" : "failed"
                $0.step = cancelled ? String(localized: "Annulée") : $0.step
                $0.error = cancelled ? nil : error.localizedDescription
            }
        }
    }

    /// Compile ServeIPA (annulable, avec journal) et retourne le dossier d'export.
    func compileServeIPA(project: URL, jobID: String) async throws -> URL {
        guard let folderURL else { throw IPARebuilder.RebuildError.unreadableFolder("—") }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let devRoot = effectiveProjectsFolder ?? folderURL.deletingLastPathComponent()
        let log = BuildLog.url(jobID: jobID)
        let blocked = isSelfUpdateBlocked
        let task = Task {
            if blocked { throw IPARebuilder.RebuildError.promptRunning("ServeIPA") }
            return try await IPARebuilder.rebuild(
                bundleIdentifier: bundleID, appName: "ServeIPA", project: project,
                devRoot: devRoot, ipaRoot: folderURL, platform: .macOS, log: log,
                progress: { [weak self] message in Task { @MainActor [weak self] in self?.showUpdateStep(message) } }
            )
        }
        activeBuild = task
        defer { activeBuild = nil }
        if cancelledJobID == jobID { task.cancel() }
        do {
            let export = try await task.value
            await removeBuilds(supersededBy: export, log: log)
            return export
        } catch {
            if let log { BuildLog.append(error.localizedDescription, to: log) }
            throw error
        }
    }

    private func showUpdateStep(_ text: String) {
        rebuildStatus = text
        updateJob(onlyIfRunning: true) { $0.step = text }
    }

    /// Confie le remplacement de ServeIPA au script d'installation, puis quitte. Ne revient qu'en levant une
    /// erreur ; le serveur est alors redémarré.
    func relaunch(with app: URL, to destination: URL, jobID: String, mustServe: Bool = false) async throws {
        let build = Bundle(url: app)?.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let serves = mustServe || serverState == .running
        isInstallingUpdate = true
        let pending = PendingUpdate(jobID: jobID, build: build)
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: DefaultsKey.pendingUpdate)
        await stopServer()
        do {
            try SelfUpdater.installAndRelaunch(app, to: destination, expectedBuild: build,
                                               healthPort: serves ? port : nil, jobID: jobID)
            // Normalement jamais atteint : l'app quitte. Au-delà, le script a renoncé.
            try await Task.sleep(for: .seconds(75))
            throw SelfUpdater.UpdateError.launchFailed(String(localized: "ServeIPA n’a pas pu quitter."))
        } catch {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.pendingUpdate)
            isInstallingUpdate = false
            if serves { await startServer() }
            throw error
        }
    }

    /// Au lancement : inscrit à l'historique le résultat de l'installation précédente.
    func resolvePendingUpdate() {
        let defaults = UserDefaults.standard
        let pending = defaults.data(forKey: DefaultsKey.pendingUpdate)
            .flatMap { try? JSONDecoder().decode(PendingUpdate.self, from: $0) }
        defaults.removeObject(forKey: DefaultsKey.pendingUpdate)

        // Le script écrit ce fichier (« job build ») quand il a restauré l'ancienne version.
        let marker = SelfUpdater.restoredMarker
        let restored = (try? String(contentsOf: marker, encoding: .utf8))?
            .split(whereSeparator: \.isWhitespace).map(String.init)
        try? FileManager.default.removeItem(at: marker)

        let running = AppBuildInfo.current.build
        let jobID: String
        let succeeded: Bool
        let expected: String
        if let restored, restored.count >= 2 {
            (jobID, expected, succeeded) = (restored[0], restored[1], false)
        } else if let pending {
            (jobID, expected, succeeded) = (pending.jobID, pending.build, pending.build == running)
        } else {
            return
        }
        let message = succeeded
            ? String(localized: "ServeIPA mis à jour (build \(running)).")
            : String(localized: "La mise à jour vers le build \(expected) a échoué : le build \(running) est conservé.")
        let job = RebuildJob(id: jobID, app: "ServeIPA", platform: IPABuild.Platform.macOS.rawValue,
                             state: succeeded ? "succeeded" : "failed", step: message,
                             error: succeeded ? nil : message, startedAt: Date(), kind: "update")
        beginJob(job)
        record(job)
        if !succeeded { rebuildError = message }
    }
}
