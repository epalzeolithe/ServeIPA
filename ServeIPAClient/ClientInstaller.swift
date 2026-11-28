#if os(macOS)
import AppKit
import Foundation

/// App ouverte qui n'a pas quitté à la demande : l'installation attend de savoir s'il faut la forcer.
struct QuitRequest: Identifiable {
    let id = UUID()
    let name: String
    let answer: CheckedContinuation<Bool, Never>
}

/// Apps qu'il ne faut pas quitter pendant qu'elles travaillent.
nonisolated enum BusyApp {
    /// rClaude lance chaque prompt dans un processus fils (`claude -p`, en local ou par SSH).
    static func isBusy(bundleIdentifier: String, pids: [Int32], processList: String) -> Bool {
        guard bundleIdentifier == "com.epalzeolithe.rClaude" else { return false }
        var children: [Int32: [(pid: Int32, command: Substring)]] = [:]
        for line in processList.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            children[parent, default: []].append((pid, fields[2]))
        }
        var pending = pids
        var seen: Set<Int32> = []
        while let parent = pending.popLast() {
            guard seen.insert(parent).inserted else { continue }
            for child in children[parent] ?? [] {
                if child.command.contains("claude -p") { return true }
                pending.append(child.pid)
            }
        }
        return false
    }

    /// Sortie de `ps` : PID, PID du parent et commande de chaque processus.
    static func processList() -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,ppid=,command="]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Cause d'un échec d'installation sur Mac.
enum InstallError: LocalizedError, Equatable {
    case extraction(String)
    case noApp
    case wrongApp(expected: String, found: String)

    var errorDescription: String? {
        switch self {
        case .extraction(let details): "L’archive reçue n’a pas pu être décompressée. \(details)"
        case .noApp: "L’archive reçue ne contient aucune app."
        case .wrongApp(let expected, let found):
            "L’archive contient « \(found) » au lieu de « \(expected) » : rien n’a été installé."
        }
    }
}

// MARK: - Installation et mise à jour sur Mac

extension ClientStore {
    /// Vrai tant qu'une installation ou une mise à jour groupée est en cours.
    var isInstalling: Bool { downloadingAppID != nil || updateBatch != nil || isCompilingUpdates }

    /// Apps installées dont le projet sur le serveur est plus avancé que la version installée.
    /// ServeIPA est exclu : sa propre mise à jour le compile au besoin.
    var compilableInstalledApps: [RemoteApp] {
        AppGroup.grouping(apps).map(\.latest).filter { app in
            guard !isServerApp(app), !isCompilationBlocked(app), let projectBuild = app.projectBuild,
                  let installed = installedApp(app), let build = Int(installed.record.build) else { return false }
            return projectBuild > build
        }
    }

    func isServerApp(_ app: RemoteApp) -> Bool {
        // Les anciens serveurs ne signalent pas leur propre app.
        app.isServer ?? (app.name == "ServeIPA")
    }

    /// Télécharge et vérifie l'app, fait quitter la version ouverte, la remplace dans Applications puis la relance
    /// (ou la lance si `launches`). Si elle ne quitte pas, rien n'est modifié sans accord pour la forcer.
    /// Retourne nil en cas de succès, sinon le message d'erreur.
    @discardableResult
    func installMac(_ app: RemoteApp, reportsError: Bool = true, inBatch: Bool = false,
                    launches: Bool = false) async -> String? {
        if isOwnApp(app) {
            await pollRebuild()
            if isUpdateBlocked(app) {
                return postpone(Self.selfUpdateBlockedMessage, reportsError: reportsError)
            }
        }
        guard downloadingAppID == nil, inBatch || updateBatch == nil else {
            let message = "Une installation est déjà en cours."
            if reportsError { errorMessage = message }
            return message
        }
        // Un serveur en cours d'exécution ne se remplace pas de l'extérieur.
        if isServerApp(app), !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty {
            return await updateRunningServer(app, reportsError: reportsError)
        }
        // Réservé avant toute attente : une seconde demande est refusée.
        downloadingAppID = app.id
        defer { downloadingAppID = nil }
        downloadedFile = nil
        downloadMessage = "Téléchargement de \(app.name)…"
        do {
            let base = try ServerAddress.parse(address)
            var components = URLComponents(url: base.appending(path: "api/v1/apps/archive"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "app", value: app.id)]
            guard let url = components?.url else { throw ClientError.invalidAddress }
            let (archive, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: archive) }
            try check(response)
            downloadMessage = "Installation de \(app.name) dans Applications…"

            let work = FileManager.default.temporaryDirectory
                .appending(path: "ServeIPAClient-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let extracted = try await Self.extract(archive: archive, into: work, bundleIdentifier: app.bundleIdentifier)
            // Une app déjà installée est remplacée là où elle se trouve, pour ne pas créer de doublon.
            let destination = installedApps[app.bundleIdentifier]?.url
                ?? Self.applicationsFolder.appending(path: extracted.lastPathComponent, directoryHint: .isDirectory)
            // Relevées avant le remplacement : ensuite, leur emplacement n'est plus fiable.
            let running = Self.instances(of: app.bundleIdentifier, at: destination)
            let installedText = "\(destination.lastPathComponent) (\(app.build)) est installée dans Applications."

            // Ce client ne peut se remplacer qu'après avoir quitté.
            if running.contains(where: { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier }) {
                downloadMessage = "Installation et relance de \(app.name)…"
                try installSelf(extracted, at: destination)
                return nil
            }
            if !running.isEmpty {
                let pids = running.map(\.processIdentifier)
                let identifier = app.bundleIdentifier
                let busy = await Task.detached {
                    BusyApp.isBusy(bundleIdentifier: identifier, pids: pids, processList: BusyApp.processList())
                }.value
                if busy {
                    return postpone("\(app.name) exécute un prompt : mise à jour reportée, rien n’a été modifié.",
                                    reportsError: reportsError)
                }
                downloadMessage = "Fermeture de \(app.name)…"
                guard await quit(running, name: app.name) else {
                    // Choix de l'utilisateur : pas d'alerte, le message reste dans le suivi.
                    return postpone("\(app.name) est restée ouverte : rien n’a été modifié.", reportsError: false)
                }
                downloadMessage = "Installation de \(app.name) dans Applications…"
            }
            do {
                try await Task.detached { try Self.replace(destination, with: extracted) }.value
            } catch {
                // L'ancienne version est toujours là : on la rouvre.
                if !running.isEmpty { await launch(destination) }
                throw error
            }
            await reloadInstalledApps()
            downloadedFile = destination
            showSuccess(installedText)
            if !running.isEmpty || launches { await launch(destination) }
            if !inBatch { announceInstallation("\(app.name) installée", "Build \(app.build)") }
            return nil
        } catch {
            downloadMessage = "Installation de \(app.name) échouée : \(error.localizedDescription)"
            if reportsError { errorMessage = error.localizedDescription }
            if !inBatch { announceInstallation("\(app.name) : installation échouée", error.localizedDescription) }
            return error.localizedDescription
        }
    }

    private func postpone(_ message: String, reportsError: Bool) -> String {
        downloadMessage = message
        if reportsError { errorMessage = message }
        return message
    }

    /// ServeIPA tourne sur ce Mac : sa mise à jour est confiée au serveur, qui s'arrête proprement, vérifie la
    /// nouvelle version et restaure l'ancienne au besoin.
    private func updateRunningServer(_ app: RemoteApp, reportsError: Bool) async -> String? {
        let local = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
        let isConnectedServer: Bool
        if let serverHostName {
            isConnectedServer = serverHostName == ProcessInfo.processInfo.hostName
        } else {
            // Ancien serveur, sans nom d'hôte : même build que l'instance locale.
            isConnectedServer = local.contains { instance in
                instance.bundleURL.flatMap { Self.installedInfo($0)?.build } == serverInfo?.build
            }
        }
        var message: String?
        if !isConnectedServer {
            message = "ServeIPA est ouvert sur ce Mac mais n’est pas le serveur connecté : quittez-le avant de l’installer."
        } else if AppGroup.grouping(apps).first(where: { $0.id == app.bundleIdentifier })?.latest.id != app.id {
            message = "ServeIPA est le serveur en cours d’exécution : seul son dernier build peut être installé."
        } else if await updateServer() {
            downloadedFile = nil
            showSuccess("Mise à jour de ServeIPA confiée au serveur.")
        } else {
            message = errorMessage ?? "La mise à jour du serveur n’a pas pu être demandée."
        }
        if let message, reportsError { errorMessage = message }
        return message
    }

    /// Installe, l'une après l'autre, toutes les apps installées qui ont une release plus récente sur le serveur.
    /// ServeIPA passe en avant-dernier et ce client en dernier, car sa relance interrompt la série.
    func updateInstalledApps() async {
        guard updateBatch == nil, downloadingAppID == nil else { return }
        let rank = { (app: RemoteApp) -> Int in
            app.bundleIdentifier == Bundle.main.bundleIdentifier ? 2 : self.isServerApp(app) ? 1 : 0
        }
        let targets = outdatedInstalledApps.sorted { rank($0) < rank($1) }
        guard !targets.isEmpty else { return }
        var failures: [String] = []
        var postponedSelf = false
        for (index, app) in targets.enumerated() {
            // Se remplacer relance ce client et effacerait les échecs à signaler.
            if app.bundleIdentifier == Bundle.main.bundleIdentifier, !failures.isEmpty {
                postponedSelf = true
                continue
            }
            updateBatch = (index, targets.count)
            let error = await installMac(app, reportsError: false, inBatch: true)
            if let error { failures.append("\(app.name) : \(error)") }
        }
        updateBatch = nil
        let done = targets.count - failures.count - (postponedSelf ? 1 : 0)
        downloadedFile = nil
        var summary = failures.isEmpty
            ? "\(done) app(s) mise(s) à jour."
            : "\(done) mise(s) à jour, \(failures.count) échec(s)."
        if postponedSelf { summary += " ServeIPAClient n’a pas été mis à jour : relancez la mise à jour." }
        if failures.isEmpty, !postponedSelf { showSuccess(summary) } else { downloadMessage = summary }
        announceInstallation("Mise à jour des apps terminée", summary)
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    /// Fait compiler par le Mac serveur les projets plus avancés que les apps installées, attend leurs releases,
    /// puis met à jour toutes les apps installées.
    func compileThenUpdate() async {
        guard !isInstalling else { return }
        isCompilingUpdates = true
        defer { isCompilingUpdates = false }
        var requested: [(app: RemoteApp, jobID: String)] = []
        for app in compilableInstalledApps {
            if let jobID = await rebuild(app) { requested.append((app, jobID)) }
        }
        downloadedFile = nil
        downloadMessage = "Compilation de \(requested.count) projet(s) sur le Mac serveur…"

        var failures: [String] = []
        var succeeded: [RemoteApp] = []
        var missing = 0
        while !requested.isEmpty {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await pollRebuild()
            var found = false
            requested.removeAll { request in
                guard let job = job(request.jobID) else { return false }
                found = true
                guard job.isFinished else { return false }
                if job.state == "succeeded" { succeeded.append(request.app) }
                else { failures.append("\(request.app.name) : \(job.detail)") }
                return true
            }
            missing = found ? 0 : missing + 1
            if missing >= 150 {
                failures += requested.map { "\($0.app.name) : la compilation ne répond plus." }
                break
            }
        }
        // Le Mac signale la fin avant d'avoir réanalysé le dossier : on attend les nouvelles releases.
        for _ in 0..<30 where !succeeded.isEmpty {
            await refreshNow()
            let latest = AppGroup.grouping(apps).map(\.latest)
            succeeded.removeAll { old in latest.contains { $0.bundleIdentifier == old.bundleIdentifier && $0.id != old.id } }
            if !succeeded.isEmpty { do { try await Task.sleep(for: .seconds(2)) } catch { return } }
        }
        failures += succeeded.map { "\($0.name) : la nouvelle release n’apparaît pas sur le serveur." }
        isCompilingUpdates = false
        if failures.isEmpty { showSuccess("Compilation terminée.") }
        else { downloadMessage = "Compilation : \(failures.count) échec(s)." }
        await updateInstalledApps()
        if !failures.isEmpty {
            errorMessage = (failures + [errorMessage].compactMap { $0 }).joined(separator: "\n")
        }
    }

    // MARK: Fichiers

    /// Décompresse l'archive dans `work` et vérifie qu'elle contient l'app annoncée par le serveur.
    nonisolated static func extract(archive: URL, into work: URL, bundleIdentifier: String) async throws -> URL {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, work.path]
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else {
            let details = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw InstallError.extraction(String(details.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)))
        }
        guard let name = try FileManager.default.contentsOfDirectory(atPath: work.path).first(where: { $0.hasSuffix(".app") }) else {
            throw InstallError.noApp
        }
        let extracted = work.appending(path: name, directoryHint: .isDirectory)
        let found = installedInfo(extracted)?.identifier ?? "app sans identifiant"
        guard found == bundleIdentifier else { throw InstallError.wrongApp(expected: bundleIdentifier, found: found) }
        return extracted
    }

    nonisolated static func replace(_ destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    // MARK: Relance

    /// Instances ouvertes depuis cet emplacement (les copies lancées depuis Xcode ne sont pas concernées).
    private static func instances(of bundleIdentifier: String, at url: URL) -> [NSRunningApplication] {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path
        }
    }

    /// Demande aux instances de quitter. Celle qui refuse n'est forcée qu'avec l'accord de l'utilisateur.
    /// Faux si l'une d'elles reste ouverte.
    private func quit(_ instances: [NSRunningApplication], name: String) async -> Bool {
        instances.forEach { _ = $0.terminate() }
        if await Self.waitForExit(instances, seconds: 8) { return true }
        guard await askToForceQuit(name) else { return false }
        instances.filter { !$0.isTerminated }.forEach { _ = $0.forceTerminate() }
        return await Self.waitForExit(instances, seconds: 3)
    }

    private func askToForceQuit(_ name: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let request = QuitRequest(name: name, answer: continuation)
            quitRequest = request
            announceInstallation("\(name) n’a pas quitté", "ServeIPAClient attend votre réponse pour l’installer.")
            // Sans réponse (fenêtre fermée), l'installation est abandonnée au bout de 5 minutes.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                self?.answerQuitRequest(request.id, force: false)
            }
        }
    }

    /// Réponse à la demande en cours ; sans effet si elle a déjà reçu la sienne.
    func answerQuitRequest(_ id: UUID, force: Bool) {
        guard let request = quitRequest, request.id == id else { return }
        quitRequest = nil
        request.answer.resume(returning: force)
    }

    private func launch(_ url: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        // Une autre copie ouverte (Xcode) ne doit pas être activée à la place de la version installée.
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            errorMessage = "Le lancement de \(url.lastPathComponent) a échoué : \(error.localizedDescription)"
        }
    }

    /// Vrai dès que toutes les instances sont arrêtées, faux après le délai.
    private static func waitForExit(_ apps: [NSRunningApplication], seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while apps.contains(where: { !$0.isTerminated }) {
            guard Date() < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return false }
        }
        return true
    }

    // MARK: Mise à jour de ce client

    /// Fichier écrit par le script quand la mise à jour de ce client a échoué.
    private static var selfUpdateFailure: URL {
        URL.libraryDirectory.appending(path: "Logs/ServeIPAClient/update-failed")
    }

    /// Arguments : PID à attendre, nouvelle app, destination, dossier temporaire à supprimer, fichier d'échec.
    nonisolated static let selfInstallScript = #"""
    pid="$1"; new="$2"; dest="$3"; staging="$4"; marker="$5"
    backup="$dest.ancienne"
    fail() { mkdir -p "$(dirname "$marker")"; printf '%s\n' "$1" > "$marker"; rm -rf "$staging"; }

    i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done
    # Une app qui n'a pas quitté n'est pas remplacée.
    if kill -0 "$pid" 2>/dev/null; then fail "ServeIPAClient n’a pas quitté : rien n’a été modifié."; exit 1; fi
    rm -rf "$backup"
    if [ -e "$dest" ] && ! mv "$dest" "$backup"; then
        fail "L’ancienne version n’a pas pu être déplacée : rien n’a été modifié."; open "$dest"; exit 1
    fi
    if ditto "$new" "$dest"; then
        rm -rf "$backup" "$staging"
        open "$dest"
    else
        rm -rf "$dest"
        if [ -e "$backup" ]; then mv "$backup" "$dest"; fi
        fail "La copie a échoué : l’ancienne version a été restaurée."
        open "$dest"
        exit 1
    fi
    """#

    /// Confie le remplacement à un shell détaché, qui attend la fin de ce client puis le relance.
    private func installSelf(_ app: URL, at destination: URL) throws {
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "ServeIPAClient-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appending(path: app.lastPathComponent, directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: app, to: staged)
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/sh")
        installer.arguments = ["-c", Self.selfInstallScript, "serveipaclient-update",
                               String(ProcessInfo.processInfo.processIdentifier), staged.path, destination.path,
                               staging.path, Self.selfUpdateFailure.path]
        try installer.run()
        // Une feuille ouverte empêcherait de quitter.
        for window in NSApplication.shared.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApplication.shared.terminate(nil)
    }

    /// Au lancement : signale l'échec de la dernière mise à jour de ce client.
    func reportFailedSelfUpdate() {
        guard let message = try? String(contentsOf: Self.selfUpdateFailure, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: Self.selfUpdateFailure)
        errorMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
