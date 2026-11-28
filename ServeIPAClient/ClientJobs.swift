import Foundation

/// État des compilations du Mac, tel que publié par `GET /api/v1/builds`.
struct BuildsStatus: Decodable {
    /// Job en cours, ou dernier job du Mac.
    let job: RebuildJob?
    /// Absents sur les anciens serveurs.
    let queue: [RebuildJob]?
    let history: [RebuildJob]?
    /// Raison pour laquelle ServeIPA peut être mis à jour (absent s'il est à jour).
    let serverUpdate: String?
    /// Projets sur lesquels rClaude exécute un prompt ; absent sur les anciens serveurs.
    let activePrompts: [String]?
    /// Change avec la liste des apps (releases, builds des projets) ; absent sur les anciens serveurs.
    var catalogRevision: String? = nil
}

/// Mise à jour du serveur lancée d'ici, suivie à travers son redémarrage.
struct ServerUpdateTracking {
    let jobID: String
    let previousBuild: String?
    var failures = 0
}

// MARK: - Suivi des compilations du Mac

extension ClientStore {
    /// Environ 5 minutes sans réponse (une tentative toutes les 2 s au plus), le temps qu'une version
    /// défaillante soit remplacée par la précédente.
    private static let maximumUpdateFailures = 150

    /// Compilations à afficher : celle en cours et la file (quel qu'en soit l'initiateur), puis celles
    /// lancées d'ici, terminées et non fermées.
    var visibleJobs: [RebuildJob] {
        let running = rebuildJob.flatMap { $0.state == "running" ? $0 : nil }
        let finished = jobHistory.filter { ownedJobIDs.contains($0.id) && !dismissedJobIDs.contains($0.id) }
        var seen: Set<String> = []
        return ([running].compactMap { $0 } + queuedJobs + finished).filter { seen.insert($0.id).inserted }
    }

    var isUpdatingServer: Bool {
        serverUpdate != nil || (queuedJobs + [rebuildJob].compactMap { $0 })
            .contains { $0.isServerUpdate && !$0.isFinished }
    }

    /// Vrai si une compilation lancée d'ici n'est pas terminée.
    var hasPendingJobs: Bool {
        visibleJobs.contains { ownedJobIDs.contains($0.id) && !$0.isFinished }
    }

    /// Vrai si rClaude exécute un prompt sur un projet portant le nom de cette app (casse, espaces et
    /// ponctuation ignorés).
    func isRunningPrompt(_ app: RemoteApp) -> Bool {
        let normalize = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let identifier = app.bundleIdentifier.split(separator: ".").last.map(String.init) ?? ""
        let names = Set([app.name, app.displayName, identifier].map(normalize)).subtracting([""])
        return activePromptProjects.contains { names.contains(normalize($0)) }
    }

    /// Vrai si rClaude exécute un prompt sur le projet de ServeIPA : ni le client ni le serveur ne se mettent
    /// alors à jour.
    var isSelfUpdateBlocked: Bool {
        let normalize = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return activePromptProjects.contains { ["serveipa", "serveipaclient"].contains(normalize($0)) }
    }

    static let selfUpdateBlockedMessage =
        "rClaude exécute un prompt sur le projet ServeIPA : mise à jour du client et du serveur indisponible."

    /// Ce client ou le serveur.
    func isOwnApp(_ app: RemoteApp) -> Bool {
        // Les anciens serveurs ne signalent pas leur propre app.
        app.bundleIdentifier == Bundle.main.bundleIdentifier || app.isServer ?? (app.name == "ServeIPA")
    }

    /// Vrai si l'installation de cette app est interdite tant que le prompt tourne.
    func isUpdateBlocked(_ app: RemoteApp) -> Bool { isSelfUpdateBlocked && isOwnApp(app) }

    /// Vrai si un prompt interdit de compiler cette app : sur son projet, ou, pour ce client et le serveur,
    /// sur l'un des deux.
    func isCompilationBlocked(_ app: RemoteApp) -> Bool { isRunningPrompt(app) || isUpdateBlocked(app) }

    /// Même règle pour un projet à ajouter, reconnu par son nom, son scheme ou son identifiant.
    func isCompilationBlocked(_ project: RemoteProject) -> Bool {
        let normalize = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let identifier = project.bundleIdentifier?.split(separator: ".").last.map(String.init)
        let names = Set([project.name, project.scheme, identifier].compactMap { $0 }.map(normalize)).subtracting([""])
        if isSelfUpdateBlocked, !names.isDisjoint(with: ["serveipa", "serveipaclient"]) { return true }
        return activePromptProjects.contains { names.contains(normalize($0)) }
    }

    static func compilationBlockedMessage(_ name: String) -> String {
        "rClaude exécute un prompt sur « \(name) » : compilation indisponible."
    }

    /// Vrai si le Mac compile cette app ou l'a en file. La baguette magique nomme l'app dans son étape
    /// (« 1/3 · App · … »).
    func isCompiling(_ app: RemoteApp) -> Bool {
        let normalize = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let identifier = app.bundleIdentifier.split(separator: ".").last.map(String.init) ?? ""
        let names = Set([app.name, app.displayName, identifier].map(normalize)).subtracting([""])
        let platform = app.isMac ? "macOS" : "iOS"
        return ([rebuildJob].compactMap { $0 } + queuedJobs).contains { job in
            guard !job.isFinished else { return false }
            if job.isMaintenance {
                let parts = job.step.components(separatedBy: " · ")
                return parts.count > 1 && names.contains(normalize(parts[1]))
            }
            return job.platform == platform && names.contains(normalize(job.app))
        }
    }

    /// Vrai si le fichier de ce build est en cours de téléchargement, d'installation ou de transfert.
    func isDownloading(_ app: RemoteApp) -> Bool {
        if downloadingAppID == app.id { return true }
        guard let pending, pending.app.id == app.id else { return false }
        switch transfer?.state {
        case "transferring": return true
        case "transferred", "failed": return false
        // iOS ne signale pas un refus : l'attente de sa confirmation n'est montrée que 2 minutes.
        default: return Date().timeIntervalSince(pending.createdAt) < 120
        }
    }

    /// Date de l'exécutable en cours (Mac), relevée une fois : un remplacement sur le disque ne la change pas.
    private static let runningBuiltAt: Date? = {
        #if os(macOS)
        return installedInfo(Bundle.main.bundleURL)?.builtAt
        #else
        return nil
        #endif
    }()

    static let serverUpdatingMessage =
        "Mise à jour du serveur en cours : le client pourra être mis à jour ensuite."

    /// Ce client attend la fin de la mise à jour du serveur, qui redémarre pendant celle-ci.
    func isWaitingForServerUpdate(_ app: RemoteApp) -> Bool {
        app.bundleIdentifier == Bundle.main.bundleIdentifier && isUpdatingServer
    }

    /// Raison pour laquelle cette app ne peut pas être installée maintenant, s'il y en a une.
    func installBlockedMessage(_ app: RemoteApp) -> String? {
        if isUpdateBlocked(app) { return Self.selfUpdateBlockedMessage }
        return isWaitingForServerUpdate(app) ? Self.serverUpdatingMessage : nil
    }

    /// Dernier build de ce client sur le serveur, quand sa release ou son projet est plus avancé que la version en
    /// cours d'exécution : c'est ce que montre déjà sa ligne dans la liste.
    var clientUpdate: RemoteApp? {
        guard let latest = AppGroup.grouping(apps).first(where: { $0.id == Bundle.main.bundleIdentifier })?.latest
        else { return nil }
        let running = InstallRecord(appID: "", version: AppBuildInfo.current.version, build: AppBuildInfo.current.build,
                                    date: Date(), builtAt: Self.runningBuiltAt)
        let projectIsNewer = Self.isNewer(latest.projectBuild, than: AppBuildInfo.current.build)
        return running.isOlder(than: latest) || projectIsNewer ? latest : nil
    }

    /// Motif de la mise à jour du serveur. Les apps listées le révèlent dès leur lecture (le compteur de build est
    /// commun au serveur et au client) ; à défaut, le motif calculé par le serveur.
    var serverUpdateMessage: String? {
        guard let server = serverInfo?.build else { return serverUpdateDetail }
        let available = AppGroup.grouping(apps).map(\.latest).filter(isOwnApp)
            .flatMap { [Int($0.build), $0.projectBuild] }.compactMap { $0 }.max()
        if let available, Self.isNewer(available, than: server) {
            return "Build \(available) disponible, serveur au build \(server)."
        }
        return serverUpdateDetail
    }

    nonisolated static func isNewer(_ build: Int?, than current: String) -> Bool {
        guard let build, let current = Int(current) else { return false }
        return build > current
    }

    func job(_ id: String) -> RebuildJob? {
        if let finished = jobHistory.first(where: { $0.id == id }) { return finished }
        if let queued = queuedJobs.first(where: { $0.id == id }) { return queued }
        return rebuildJob?.id == id ? rebuildJob : nil
    }

    func dismiss(_ job: RebuildJob) {
        dismissedJobIDs = Array((dismissedJobIDs + [job.id]).suffix(50))
    }

    /// Mémorise un job lancé d'ici : son résultat sera affiché et notifié.
    func track(_ jobID: String) {
        // Le serveur rend le même identifiant pour une demande déjà en file.
        ownedJobIDs = Array((ownedJobIDs.filter { $0 != jobID } + [jobID]).suffix(50))
        ClientNotifications.shared.requestAuthorization()
    }

    func resetJobs() {
        serverUpdate = nil
        rebuildJob = nil
        queuedJobs = []
        jobHistory = []
        localResults = []
        ownBuiltApps = []
        knownFinishedIDs = nil
        serverUpdateDetail = nil
        activePromptProjects = []
        catalogRevision = nil
        requestedProjects = [:]
    }

    func pollRebuild() async {
        if serverUpdate != nil {
            await pollServerUpdate()
            return
        }
        guard isConnected, let base = try? ServerAddress.parse(address) else { return }
        guard let status = try? await buildsStatus(base) else {
            rebuildJob = nil
            queuedJobs = []
            activePromptProjects = []
            return
        }
        // Un job vient de se terminer ou le Mac signale un changement : la liste des apps est relue.
        if apply(status) { await refreshNow() }
    }

    /// Vrai s'il reste quelque chose à surveiller quand l'app passe en arrière-plan.
    var needsBackgroundCheck: Bool {
        hasPendingJobs || [NotificationKind.releases, .serverUpdate, .failures].contains { $0.isEnabled }
    }

    /// Vérification sans interface (arrière-plan iOS) : notifie les jobs terminés et les nouveautés.
    /// Retourne vrai s'il faut vérifier de nouveau.
    func checkJobsInBackground() async -> Bool {
        if let base = try? ServerAddress.parse(address), let status = try? await buildsStatus(base) {
            _ = apply(status)
            await refresh()
        }
        return needsBackgroundCheck
    }

    private func buildsStatus(_ base: URL) async throws -> BuildsStatus {
        let data = try await request(base.appending(path: "api/v1/builds"))
        return try JSONDecoder().decode(BuildsStatus.self, from: data)
    }

    /// Enregistre l'état publié par le Mac. Vrai si la liste des apps est à relire.
    private func apply(_ status: BuildsStatus) -> Bool {
        rebuildJob = status.job
        queuedJobs = status.queue ?? []
        serverUpdateDetail = status.serverUpdate
        activePromptProjects = status.activePrompts ?? []
        var finished = status.history ?? []
        // Un ancien serveur ne publie que le job courant.
        if let job = status.job, job.isFinished, !finished.contains(where: { $0.id == job.id }) {
            finished.insert(job, at: 0)
        }
        finished += localResults.filter { local in !finished.contains { $0.id == local.id } }
        jobHistory = finished

        let ids = Set(finished.map(\.id))
        let hasNew = knownFinishedIDs.map { !ids.isSubset(of: $0) } ?? false
        knownFinishedIDs = ids.union(knownFinishedIDs ?? [])
        finished.forEach(announce)
        finished.forEach(scheduleDismissal)
        announceForeignFailures(finished)
        announceServerUpdate(status.serverUpdate)
        // Premier relevé : la liste vient d'être lue.
        var catalogChanged = false
        if let revision = status.catalogRevision, revision != catalogRevision {
            catalogChanged = catalogRevision != nil
            catalogRevision = revision
        }
        return hasNew || catalogChanged
    }

    /// Notifie une fois la fin d'un job lancé d'ici.
    private func announce(_ job: RebuildJob) {
        guard job.isFinished, ownedJobIDs.contains(job.id), !notifiedJobIDs.contains(job.id) else { return }
        notifiedJobIDs = Array((notifiedJobIDs + [job.id]).suffix(50))
        if job.state == "succeeded" { ownBuiltApps.insert(job.app) }
        if job.state != "cancelled" {
            let title = job.state == "succeeded" ? "\(job.app) : terminé" : "\(job.app) : échec"
            ClientNotifications.shared.post(.jobs, id: job.id, title: title, body: job.detail)
        }
    }

    /// Referme après quelques secondes les jobs lancés d'ici et terminés sans échec. Reprogrammé à chaque lancement :
    /// la fermeture ne doit pas dépendre de la notification, qui n'a lieu qu'une fois (client quitté ou suspendu
    /// entre-temps).
    private func scheduleDismissal(_ job: RebuildJob) {
        guard job.isFinished, job.state != "failed", ownedJobIDs.contains(job.id),
              !dismissedJobIDs.contains(job.id), scheduledDismissals.insert(job.id).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.successDisplayTime)
            self?.dismiss(job)
            self?.scheduledDismissals.remove(job.id)
        }
    }

    func cancel(_ job: RebuildJob) async {
        do {
            let url = try jobURL("api/v1/builds", job: job.id)
            _ = try await request(url, method: "DELETE")
            await pollRebuild()
        } catch ClientError.http(404) {
            errorMessage = "Ce travail ne peut plus être annulé : il est terminé ou en cours d’installation."
        } catch ClientError.http(405) {
            errorMessage = "Annulation indisponible : ServeIPA doit être mis à jour sur le Mac."
        } catch {
            errorMessage = "Annulation impossible : \(error.localizedDescription)"
        }
    }

    /// Fin du journal de compilation conservé sur le Mac.
    func buildLog(_ jobID: String) async throws -> String {
        let data = try await request(jobURL("api/v1/builds/log", job: jobID))
        return String(decoding: data, as: UTF8.self)
    }

    private func jobURL(_ path: String, job: String) throws -> URL {
        let base = try ServerAddress.parse(address)
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "job", value: job)]
        guard let url = components?.url else { throw ClientError.invalidAddress }
        return url
    }

    // MARK: Mise à jour du serveur

    /// Demande au Mac de mettre ServeIPA à jour (en le compilant si nécessaire) puis de le relancer.
    @discardableResult
    func updateServer() async -> Bool {
        // État des prompts relu à l'instant : le dernier relevé peut dater.
        await pollRebuild()
        guard !isSelfUpdateBlocked else {
            errorMessage = Self.selfUpdateBlockedMessage
            return false
        }
        do {
            let base = try ServerAddress.parse(address)
            let previousBuild = try await serverBuild(base)
            let data = try await request(base.appending(path: "api/v1/server/update"), method: "POST")
            struct Started: Decodable { let id: String }
            let jobID = try JSONDecoder().decode(Started.self, from: data).id
            track(jobID)
            serverUpdate = ServerUpdateTracking(jobID: jobID, previousBuild: previousBuild)
            await pollRebuild()
            return true
        } catch ClientError.http(409) {
            errorMessage = "Le Mac ne peut pas accepter de mise à jour pour le moment."
        } catch ClientError.http(let code) where code == 404 || code == 405 || code == 503 {
            errorMessage = "Mise à jour à distance indisponible (HTTP \(code)) : mettez d’abord ServeIPA à jour depuis le Mac."
        } catch {
            errorMessage = "Mise à jour impossible : \(error.localizedDescription)"
        }
        return false
    }

    private func serverBuild(_ base: URL) async throws -> String? {
        struct Health: Decodable { let serverBuild: String? }
        let data = try await request(base.appending(path: "api/v1/health"))
        return try JSONDecoder().decode(Health.self, from: data).serverBuild
    }

    /// Le serveur inscrit le résultat à son historique au redémarrage. À défaut (ancienne version), il se lit
    /// au numéro de build.
    private func pollServerUpdate() async {
        guard let update = serverUpdate, let base = try? ServerAddress.parse(address) else { return }
        do {
            let status = try await buildsStatus(base)
            guard serverUpdate?.jobID == update.jobID else { return }
            serverUpdate?.failures = 0
            let hasNew = apply(status)
            if jobHistory.contains(where: { $0.id == update.jobID }) {
                serverUpdate = nil
                await refresh()
                return
            }
            if job(update.jobID) != nil {
                if hasNew { await refresh() }
                return
            }
            let build = try await serverBuild(base)
            guard serverUpdate?.jobID == update.jobID else { return }
            if let build, build != update.previousBuild {
                finishServerUpdate(update.jobID, state: "succeeded",
                                   text: "ServeIPA mis à jour : build \(update.previousBuild ?? "—") → \(build).")
            } else {
                finishServerUpdate(update.jobID, state: "failed",
                                   text: "ServeIPA a redémarré sans changer de version.")
            }
            await refresh()
        } catch {
            guard serverUpdate?.jobID == update.jobID else { return }
            serverUpdate?.failures += 1
            if update.failures >= Self.maximumUpdateFailures {
                finishServerUpdate(update.jobID, state: "failed",
                                   text: "Le serveur ne répond plus. Vérifiez ServeIPA sur le Mac.")
            } else {
                queuedJobs = []
                rebuildJob = .serverUpdate(update.jobID, state: "running",
                                           text: "Serveur injoignable, redémarrage probable…")
            }
        }
    }

    private func finishServerUpdate(_ id: String, state: String, text: String) {
        let result = RebuildJob.serverUpdate(id, state: state, text: text)
        serverUpdate = nil
        rebuildJob = result
        localResults.append(result)
        jobHistory.insert(result, at: 0)
        announce(result)
        scheduleDismissal(result)
    }
}
