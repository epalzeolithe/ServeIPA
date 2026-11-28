import AppKit
import Foundation
import ImageIO
import Observation
import ServiceManagement

@MainActor
@Observable
final class IPAStore {
    enum ServerState: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var title: LocalizedStringResource {
            switch self {
            case .stopped: "Arrêté"
            case .starting: "Démarrage…"
            case .running: "En service"
            case .failed: "Erreur"
            }
        }

        var symbolName: String {
            switch self {
            case .running: "server.rack"
            case .starting: "arrow.trianglehead.2.clockwise.rotate.90"
            case .stopped: "server.rack"
            case .failed: "exclamationmark.triangle"
            }
        }
    }

    enum DefaultsKey {
        static let folderBookmark = "ipaFolderBookmark"
        static let startServerAutomatically = "startServerAutomatically"
        static let keepBuildsPerApp = "keepBuildsPerApp"
        static let projectsBookmark = "projectsFolderBookmark"
        static let hideDockIcon = "hideDockIcon"
        static let nightlyBuild = "nightlyBuild"
        static let lastNightlyRun = "lastNightlyRun"
        static let startServerAfterUpdate = "startServerAfterUpdate"
        static let pendingUpdate = "pendingUpdate"
        static let jobHistory = "jobHistory"
    }

    var builds: [IPABuild] = []
    var scanIssues: [ScanIssue] = []
    var serverState: ServerState = .stopped
    var serverURL: URL?
    var selectedBuildID: String?
    var folderURL: URL?
    var isScanning = false
    /// Baguette magique en cours (manuelle, nightly ou demandée par un client).
    private(set) var isRunningMaintenance = false
    /// Identifiant de bundle de l'app en cours de recompilation, son étape et la dernière erreur.
    var rebuildingBundleID: String?
    var rebuildStatus: String?
    var rebuildError: String?
    /// Résultat de la dernière installation dans /Applications.
    var installMessage: String?
    /// Apps non installées dans /Applications parce qu'elles sont restées ouvertes ou sont occupées.
    private var postponedApps: [String] = []
    /// Incrémenté après chaque copie dans /Applications, pour rafraîchir les badges « déjà installée ».
    private(set) var installRevision = 0
    var currentJob: RebuildJob?
    /// Demandes des clients en attente, et la tâche qui les exécute l'une après l'autre.
    var pendingJobs: [QueuedJob] = []
    var queueTask: Task<Void, Never>?
    var runningQueueKey: String?
    /// Derniers jobs terminés, du plus récent au plus ancien.
    var jobHistory: [RebuildJob] = UserDefaults.standard.data(forKey: DefaultsKey.jobHistory)
        .flatMap { try? JSONDecoder().decode([RebuildJob].self, from: $0) } ?? []
    /// Compilation en cours (annulable) et job dont l'annulation est demandée.
    var activeBuild: Task<URL, Error>?
    var cancelledJobID: String?
    /// ServeIPA est sur le point de se remplacer : plus aucune demande n'est acceptée.
    var isInstallingUpdate = false
    /// Mise à jour de ServeIPA disponible (nil s'il est à jour).
    var serverUpdateDetail: String?
    /// Projets sur lesquels rClaude exécute un prompt en ce moment.
    var activePromptProjects: [String] = []
    private var lastUpdateCheck = Date.distantPast
    private var hasStarted = false
    /// Dossier contenant les projets Xcode ; par défaut, le dossier parent des IPA.
    var projectsFolderURL: URL?
    /// Dossier réellement utilisé pour chercher les projets (choisi, sinon parent du dossier des IPA).
    var effectiveProjectsFolder: URL? { projectsFolderURL ?? folderURL?.deletingLastPathComponent() }

    /// Résultat du dernier scan des projets Xcode.
    var scannedProjects: [ScannedProject] = []
    var isScanningProjects = false
    /// Projets inspectés / trouvés pendant le scan en cours.
    var projectScanProgress: (done: Int, total: Int)?
    var projectScanError: String?
    /// Ajout en cours depuis le scan, et état de chaque élément (clé : `addKey`).
    var isAddingProjects = false
    var projectAddStates: [String: ProjectAddState] = [:]

    enum ProjectAddState: Equatable {
        case queued
        case building(String)
        case added
        case failed(String)
    }
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var startServerAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(startServerAutomatically, forKey: DefaultsKey.startServerAutomatically)
        }
    }

    /// Chaque nuit à 1 h, si le serveur tourne : recompile les apps dépassées, nettoie les anciennes
    /// versions et copie les releases dans /Applications.
    var nightlyBuild: Bool {
        didSet {
            UserDefaults.standard.set(nightlyBuild, forKey: DefaultsKey.nightlyBuild)
        }
    }

    /// Masque l'icône du Dock (l'app reste accessible depuis la barre des menus).
    var hideDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(hideDockIcon, forKey: DefaultsKey.hideDockIcon)
            applyDockIconVisibility()
            if !hideDockIcon {
                NSApplication.shared.activate()
            }
        }
    }

    private func applyDockIconVisibility() {
        NSApplication.shared.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }

    /// Nombre de builds conservés par app (identifiant de bundle). 0 = nettoyage désactivé.
    var keepBuildsPerApp: Int {
        didSet {
            UserDefaults.standard.set(keepBuildsPerApp, forKey: DefaultsKey.keepBuildsPerApp)
            Task { await refresh() }
        }
    }

    let port: UInt16 = 8765
    var server: OTAServer?
    private var isAccessingSecurityScopedFolder = false

    init() {
        UserDefaults.standard.register(defaults: [DefaultsKey.startServerAutomatically: true,
                                                  DefaultsKey.nightlyBuild: true])
        nightlyBuild = UserDefaults.standard.bool(forKey: DefaultsKey.nightlyBuild)
        startServerAutomatically = UserDefaults.standard.bool(forKey: DefaultsKey.startServerAutomatically)
        keepBuildsPerApp = UserDefaults.standard.integer(forKey: DefaultsKey.keepBuildsPerApp)
        hideDockIcon = UserDefaults.standard.bool(forKey: DefaultsKey.hideDockIcon)
        if hideDockIcon {
            applyDockIconVisibility()
        }
        restoreFolder()
        restoreProjectsFolder()
    }

    // MARK: Scan des projets Xcode

    /// Clé d'un projet à ajouter pour une plateforme.
    func addKey(_ project: ScannedProject, _ platform: IPABuild.Platform) -> String {
        "\(project.id)|\(platform.rawValue)"
    }

    /// Vrai si le dossier des IPA contient déjà un build de cette app pour cette plateforme.
    func isServed(_ project: ScannedProject, platform: IPABuild.Platform) -> Bool {
        if let bundle = project.bundleIdentifier,
           builds.contains(where: { $0.bundleIdentifier == bundle && $0.platform == platform }) {
            return true
        }
        // Identifiant changé depuis l'export (ex. ancien « devplaceholder… ») : on compare aussi le nom.
        let normalize = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let names = [project.productName, project.scheme].compactMap { $0 }.map(normalize)
        return builds.contains { $0.platform == platform && names.contains(normalize($0.name)) }
    }

    /// Cherche les projets Xcode du dossier des projets et lit l'app que chacun produit (4 à la fois).
    func scanProjects() async {
        guard !isScanningProjects, let root = effectiveProjectsFolder else { return }
        isScanningProjects = true
        projectScanError = nil
        if !isAddingProjects { projectAddStates = [:] }
        defer {
            isScanningProjects = false
            projectScanProgress = nil
        }
        let ipaRoot = folderURL
        do {
            let projects = try await Task.detached { try XcodeProjectScanner.findProjects(in: root, excluding: ipaRoot) }.value
            projectScanProgress = (0, projects.count)
            var found: [ScannedProject] = []
            var done = 0
            await withTaskGroup(of: [ScannedProject].self) { group in
                var pending = projects.makeIterator()
                for _ in 0..<6 {
                    guard let project = pending.next() else { break }
                    group.addTask { XcodeProjectScanner.inspect(project) }
                }
                for await apps in group {
                    found += apps
                    done += 1
                    projectScanProgress = (done, projects.count)
                    if let next = pending.next() {
                        group.addTask { XcodeProjectScanner.inspect(next) }
                    }
                }
            }
            scannedProjects = found.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        } catch {
            scannedProjects = []
            projectScanError = error.localizedDescription
        }
    }

    /// Compile et exporte chaque projet choisi, l'un après l'autre (une seule compilation à la fois).
    func addProjects(_ selection: [(project: ScannedProject, platform: IPABuild.Platform)]) async {
        guard !isAddingProjects, rebuildingBundleID == nil, !selection.isEmpty else { return }
        isAddingProjects = true
        defer { isAddingProjects = false }
        for item in selection { projectAddStates[addKey(item.project, item.platform)] = .queued }
        for item in selection {
            let key = addKey(item.project, item.platform)
            projectAddStates[key] = .building(String(localized: "Compilation…"))
            let name = item.project.displayName
            if let error = await runRebuild(label: name, bundleIdentifier: item.project.bundleIdentifier, appName: name,
                                            project: item.project.url, scheme: item.project.scheme,
                                            platform: item.platform,
                                            reportsError: false, onStep: { [weak self] step in
                                                self?.projectAddStates[key] = .building(step)
                                            }) {
                projectAddStates[key] = .failed(error)
            } else {
                projectAddStates[key] = .added
            }
        }
    }

    // MARK: Mise à jour de ServeIPA

    /// Vrai si rClaude exécute un prompt sur le projet de ServeIPA : il ne se met alors pas à jour d'ici.
    var isSelfUpdateBlocked: Bool {
        PromptActivity.concerns(activePromptProjects, names: ["ServeIPA", "ServeIPAClient"],
                                bundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    }

    /// Vrai si rClaude exécute un prompt sur le projet de ce build : il ne peut alors pas être compilé.
    func isCompilationBlocked(_ build: IPABuild) -> Bool {
        PromptActivity.blocksCompilation(activePromptProjects, names: [build.name, build.displayName],
                                         bundleIdentifier: build.bundleIdentifier)
    }

    /// Recompile ServeIPA depuis son projet (macOS, Release), puis le remplace et le relance.
    func updateServeIPA() async {
        guard rebuildingBundleID == nil, !isAddingProjects, !isRunningMaintenance, pendingJobs.isEmpty else {
            rebuildError = String(localized: "Une compilation est déjà en cours. Réessayez quand elle sera terminée.")
            return
        }
        guard let folderURL, let devRoot = effectiveProjectsFolder else {
            rebuildError = String(localized: "Choisissez d’abord le dossier des IPA.")
            return
        }
        let destination = SelfUpdater.installLocation
        let alert = NSAlert()
        alert.messageText = String(localized: "Mettre à jour ServeIPA ?")
        var details = String(localized: "ServeIPA va se recompiler depuis son projet Xcode (Release), puis se fermer, s’installer dans « \(destination.path) » et se relancer. Le serveur sera interrompu quelques secondes et les suivis d’installation en cours seront perdus.")
        if SelfUpdater.runsFromBuildFolder {
            details += "\n\n" + String(localized: "ServeIPA tourne actuellement depuis Xcode : la nouvelle version sera installée dans Applications, et c’est elle qui sera relancée.")
        }
        alert.informativeText = details
        alert.addButton(withTitle: String(localized: "Mettre à jour"))
        alert.addButton(withTitle: String(localized: "Annuler"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Un prompt a pu démarrer pendant la confirmation.
        guard !isSelfUpdateBlocked else {
            rebuildError = String(localized: "Prompt rClaude en cours sur le projet ServeIPA : mise à jour indisponible.")
            return
        }

        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let jobID = UUID().uuidString
        rebuildingBundleID = "ServeIPA"
        rebuildStatus = String(localized: "Recherche du projet…")
        rebuildError = nil
        beginJob(RebuildJob(id: jobID, app: "ServeIPA", platform: IPABuild.Platform.macOS.rawValue, state: "running",
                            step: String(localized: "Préparation…"), error: nil, startedAt: Date(), kind: "update"))
        do {
            let project = try await Task.detached {
                try IPARebuilder.findProject(bundleIdentifier: bundleID, appName: "ServeIPA", devRoot: devRoot, ipaRoot: folderURL)
            }.value
            let export = try await compileServeIPA(project: project, jobID: jobID)
            let app = try SelfUpdater.exportedApp(in: export)
            rebuildStatus = String(localized: "Installation et relance…")
            try await relaunch(with: app, to: destination, jobID: jobID)
        } catch {
            let cancelled = cancelledJobID == jobID
            if !cancelled { rebuildError = error.localizedDescription }
            updateJob {
                $0.state = cancelled ? "cancelled" : "failed"
                $0.error = cancelled ? nil : error.localizedDescription
            }
            rebuildingBundleID = nil
            rebuildStatus = nil
            await refresh()
        }
    }

    func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choisir le dossier des projets Xcode")
        panel.message = String(localized: "ServeIPA y cherchera le projet de chaque app à recompiler.")
        panel.prompt = String(localized: "Choisir")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectsFolderURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        projectsFolderURL = url
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: DefaultsKey.projectsBookmark)
        }
    }

    private func restoreProjectsFolder() {
        guard let bookmark = UserDefaults.standard.data(forKey: DefaultsKey.projectsBookmark) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        _ = url.startAccessingSecurityScopedResource()
        projectsFolderURL = url
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choisir le dossier des IPA")
        panel.message = String(localized: "Les IPA placés dans ses sous-dossiers seront proposés au téléchargement.")
        panel.prompt = String(localized: "Choisir")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolder(url)
        if case .failed = serverState {
            serverState = .stopped
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard let folderURL else {
            builds = []
            scanIssues = []
            return
        }
        isScanning = true
        var result = await Task.detached {
            Self.scan(folderURL)
        }.value
        let keep = keepBuildsPerApp
        if keep > 0 {
            let removed = await Task.detached {
                Self.pruneOldBuilds(result.builds, keep: keep, rootURL: folderURL)
            }.value
            if removed > 0 {
                result = await Task.detached { Self.scan(folderURL) }.value
            }
        }
        builds = result.builds
        scanIssues = result.issues
        isScanning = false

        if let selectedBuildID, !builds.contains(where: { $0.id == selectedBuildID }) {
            self.selectedBuildID = nil
        }
        server?.update(builds: builds, rootURL: folderURL, publicURL: serverURL)
        Task { await updateNewerProjectBuilds() }
    }

    /// Numéro de build du projet, par identifiant de build, pour les releases dont le projet est plus récent.
    var newerProjectBuilds: [String: Int] = [:]
    /// Dates git du projet, par identifiant du build le plus récent de chaque app.
    private var projectGitDates: [String: ProjectGitDates] = [:]
    private var projectBuildsTask: Task<Void, Never>?
    private var isReadingGitDates = false
    private var isRunningGitAction = false
    private var lastGitRead = Date.distantPast
    private var gitDatesReleases: Set<String> = []

    /// Stage et commit (puis push) du projet d'une app, à la demande d'un client. Refusé pendant une compilation,
    /// qui écrit dans les projets, ou une autre action git.
    func runGitAction(_ build: IPABuild, message: String, push: Bool) async -> GitActionResult {
        guard !isRunningGitAction, !isBusy else {
            return GitActionResult(succeeded: false, message: "Le Mac est occupé (compilation ou autre action git).")
        }
        guard let folderURL, let devRoot = effectiveProjectsFolder else {
            return GitActionResult(succeeded: false, message: "Le dossier des projets n’est pas choisi sur le Mac.")
        }
        isRunningGitAction = true
        defer { isRunningGitAction = false }
        let result = await Task.detached {
            do {
                let project = try IPARebuilder.findProject(bundleIdentifier: build.bundleIdentifier, appName: build.name,
                                                           devRoot: devRoot, ipaRoot: folderURL)
                return GitActions.commit(folder: project.deletingLastPathComponent(), message: message, push: push)
            } catch {
                return GitActionResult(succeeded: false, message: error.localizedDescription)
            }
        }.value
        // Les dates et numéros de commit et de push sont relus sans attendre.
        lastGitRead = .distantPast
        Task { await updateNewerProjectBuilds() }
        return result
    }

    /// Compare le build le plus récent de chaque app au numéro de build courant de son projet Xcode. Une demande
    /// faite pendant un calcul attend celui-ci au lieu d'en lancer un second.
    func updateNewerProjectBuilds() async {
        if let projectBuildsTask {
            await projectBuildsTask.value
            return
        }
        let task = Task { await computeNewerProjectBuilds() }
        projectBuildsTask = task
        await task.value
        projectBuildsTask = nil
    }

    private func computeNewerProjectBuilds() async {
        guard let folderURL, let devRoot = effectiveProjectsFolder else {
            newerProjectBuilds = [:]
            projectGitDates = [:]
            server?.setProjectBuilds([:])
            server?.setProjectGitDates([:])
            return
        }
        let latest = Dictionary(grouping: builds, by: { "\($0.platform.rawValue)/\($0.bundleIdentifier)" })
            .values.compactMap { group in
                group.max { ($0.folderDate ?? $0.folderName, Int($0.build) ?? -1) < ($1.folderDate ?? $1.folderName, Int($1.build) ?? -1) }
            }
        let result = await Task.detached {
            var projectBuilds: [URL: Int?] = [:]
            var newer: [String: Int] = [:]
            var projects: [String: URL] = [:]
            for build in latest {
                guard let project = try? IPARebuilder.findProject(bundleIdentifier: build.bundleIdentifier, appName: build.name,
                                                                  devRoot: devRoot, ipaRoot: folderURL) else { continue }
                projects[build.id] = project
                guard let released = Int(build.build) else { continue }
                let current = projectBuilds[project] ?? ProjectBuildNumber.read(project: project)
                projectBuilds[project] = current
                if let current, current > released { newer[build.id] = current }
            }
            return (newer: newer, projects: projects)
        }.value
        newerProjectBuilds = result.newer
        server?.setProjectBuilds(result.newer)
        updateProjectGitDates(result.projects)
    }

    /// Les dates git demandent plusieurs commandes par projet : elles sont relevées à part, sans retarder les numéros
    /// de build, au plus toutes les 30 secondes tant que les releases ne changent pas.
    private func updateProjectGitDates(_ projects: [String: URL]) {
        let releases = Set(projects.keys)
        guard !isReadingGitDates,
              releases != gitDatesReleases || Date().timeIntervalSince(lastGitRead) >= 30 else { return }
        isReadingGitDates = true
        Task {
            let dates = await Task.detached {
                var byProject: [URL: ProjectGitDates] = [:]
                return projects.mapValues { project in
                    let dates = byProject[project] ?? ProjectGitDates.read(project: project)
                    byProject[project] = dates
                    return dates
                }
            }.value
            projectGitDates = dates
            server?.setProjectGitDates(dates)
            gitDatesReleases = releases
            lastGitRead = Date()
            isReadingGitDates = false
        }
    }

    /// Nombre de builds qui ne sont pas le plus récent de leur app (par plateforme).
    var oldBuildCount: Int {
        builds.count - Set(builds.map { "\($0.platform.rawValue)/\($0.bundleIdentifier)" }).count
    }

    /// Supprime définitivement du disque toutes les anciennes versions, en ne gardant que le build le plus récent de chaque app.
    func cleanOldVersions() async {
        // Attend la fin d'une éventuelle analyse (rafraîchissement auto toutes les 5 s) au lieu d'abandonner.
        while isScanning { try? await Task.sleep(for: .milliseconds(100)) }
        guard let folderURL else { return }
        await refresh()
        let current = builds
        _ = await Task.detached {
            Self.pruneOldBuilds(current, keep: 1, rootURL: folderURL)
        }.value
        await refresh()
    }

    /// Builds les plus récents dont le projet Xcode est à un numéro de build plus avancé.
    var outdatedBuilds: [IPABuild] { builds.filter { newerProjectBuilds[$0.id] != nil } }

    /// Recompile, l'un après l'autre, chaque app dont le projet est plus récent que sa release, puis
    /// (si `clean`) supprime les anciennes versions. Retourne les échecs.
    @discardableResult
    func updateOutdatedBuilds(thenClean clean: Bool) async -> [String] {
        while isScanning { try? await Task.sleep(for: .milliseconds(100)) }
        guard !isAddingProjects, rebuildingBundleID == nil else {
            return [String(localized: "Une compilation est déjà en cours.")]
        }
        // Les projets sur lesquels un prompt tourne sont laissés pour plus tard.
        let targets = outdatedBuilds.filter { !isCompilationBlocked($0) }
        var failures: [String] = []
        let jobID = currentJob?.id
        for (index, build) in targets.enumerated() {
            if let jobID, cancelledJobID == jobID { return failures }
            let position = "\(index + 1)/\(targets.count)"
            let error = await runRebuild(
                label: build.bundleIdentifier, bundleIdentifier: build.bundleIdentifier, appName: build.name,
                project: nil, platform: build.platform, reportsError: false, managesJob: false,
                onStep: { [weak self] step in
                    let status = "\(position) · \(build.name) · \(step)"
                    self?.rebuildStatus = status
                    self?.updateJob(onlyIfRunning: true) { $0.step = status }
                }
            )
            if let jobID, cancelledJobID == jobID { return failures }
            if let error { failures.append("\(build.name) (\(build.platform.rawValue)) : \(error)") }
        }
        if clean, jobID == nil || cancelledJobID != jobID {
            updateJob(onlyIfRunning: true) { $0.step = String(localized: "Suppression des anciennes versions…") }
            await cleanOldVersions()
        }
        if !failures.isEmpty { rebuildError = failures.joined(separator: "\n\n") }
        return failures
    }

    /// Recompile l'app de ce build depuis son projet Xcode (dossier parent du dossier des IPA)
    /// et exporte un nouvel IPA dans le dossier des IPA.
    func rebuild(_ build: IPABuild) async {
        await runRebuild(label: build.bundleIdentifier, bundleIdentifier: build.bundleIdentifier,
                         appName: build.name, project: nil, platform: build.platform)
    }

    /// Ajoute une app : l'utilisateur choisit son projet Xcode, qui est compilé pour `platform`
    /// et exporté dans le dossier des IPA.
    func addApp(platform: IPABuild.Platform) async {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choisir le projet Xcode de l’app")
        panel.prompt = String(localized: "Compiler")
        // Un .xcodeproj est un paquet : le filtrer par type le grise, on laisse donc le délégué décider.
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let delegate = XcodeProjectPanelDelegate()
        panel.delegate = delegate
        panel.directoryURL = projectsFolderURL ?? folderURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "xcodeproj" else {
            rebuildError = String(localized: "Choisissez un fichier projet Xcode (.xcodeproj).")
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        await runRebuild(label: name, bundleIdentifier: nil, appName: name, project: url, platform: platform)
    }

    /// Scan demandé par un client distant : retourne les projets en JSON. Pendant une compilation, le dernier
    /// résultat est renvoyé sans nouveau scan.
    func remoteProjectsJSON() async -> Data? {
        // Un scan déjà en cours (fenêtre du Mac) est attendu plutôt que doublé.
        if isScanningProjects {
            while isScanningProjects { try? await Task.sleep(for: .milliseconds(100)) }
        } else if !isBusy || scannedProjects.isEmpty {
            await scanProjects()
        }
        let root = effectiveProjectsFolder
        let projects: [[String: Any]] = scannedProjects.map { project in
            var object: [String: Any] = [
                "id": project.id,
                "name": project.displayName,
                "platforms": project.platforms.map { ["name": $0.rawValue, "served": isServed(project, platform: $0)] }
            ]
            object["scheme"] = project.scheme
            object["bundleIdentifier"] = project.bundleIdentifier
            object["problem"] = project.problem
            object["folder"] = root.map { project.relativeFolder(to: $0) }
            return object
        }
        var envelope: [String: Any] = ["apiVersion": 1, "projects": projects]
        envelope["error"] = projectScanError
        return try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    /// Met en file l'ajout d'un projet du dernier scan, demandé par un client distant.
    func startRemoteAddProject(id: String, platform: String) -> ProjectAddResult {
        guard let project = scannedProjects.first(where: { $0.id == id }), project.problem == nil,
              let target = project.platforms.first(where: { $0.rawValue == platform }) else { return .notFound }
        let name = project.displayName
        let jobID = enqueue(app: name, platform: platform, kind: "rebuild", key: "add/\(platform)/\(id)") { [weak self] jobID in
            await self?.runRebuild(label: name, bundleIdentifier: project.bundleIdentifier, appName: name,
                                   project: project.url, scheme: project.scheme, platform: target, jobID: jobID)
        }
        return jobID.map { .started($0) } ?? .busy
    }

    /// Met en file une recompilation demandée par un client distant ; retourne l'identifiant du job.
    func startRemoteRebuild(_ build: IPABuild) -> String? {
        enqueue(app: build.name, platform: build.platform.rawValue, kind: "rebuild",
                key: "rebuild/\(build.platform.rawValue)/\(build.bundleIdentifier)") { [weak self] jobID in
            await self?.runRebuild(label: build.bundleIdentifier, bundleIdentifier: build.bundleIdentifier,
                                   appName: build.name, project: nil, platform: build.platform, jobID: jobID)
        }
    }

    /// Met en file la mise à jour de ServeIPA demandée par un client distant.
    func startRemoteServerUpdate() -> String? {
        enqueue(app: "ServeIPA", platform: IPABuild.Platform.macOS.rawValue, kind: "update", key: "update") { [weak self] jobID in
            await self?.runRemoteServerUpdate(jobID: jobID)
        }
    }

    func updateJob(onlyIfRunning: Bool = false, _ change: (inout RebuildJob) -> Void) {
        guard var job = currentJob, !onlyIfRunning || job.state == "running" else { return }
        let wasRunning = job.state == "running"
        change(&job)
        currentJob = job
        server?.setRebuildJob(job)
        if wasRunning, job.state != "running" { record(job) }
    }

    /// Retourne nil en cas de succès, sinon le message d'erreur (affiché dans une alerte si `reportsError`).
    @discardableResult
    private func runRebuild(label: String, bundleIdentifier: String?, appName: String,
                            project: URL?, scheme: String? = nil, platform: IPABuild.Platform,
                            jobID: String = UUID().uuidString,
                            reportsError: Bool = true, managesJob: Bool = true,
                            onStep: (@MainActor (String) -> Void)? = nil) async -> String? {
        guard let folderURL, rebuildingBundleID == nil else {
            return String(localized: "Une compilation est déjà en cours, ou le dossier des IPA n’est pas choisi.")
        }
        var failure: String?
        rebuildingBundleID = label
        rebuildStatus = nil
        rebuildError = nil
        if managesJob {
            beginJob(RebuildJob(id: jobID, app: appName, platform: platform.rawValue, state: "running",
                                step: String(localized: "Préparation…"), error: nil, startedAt: Date()))
        }
        // Une maintenance regroupe ses compilations dans le journal de son propre job.
        let ownerID = managesJob ? jobID : currentJob?.id ?? jobID
        let log = BuildLog.url(jobID: ownerID)
        if let log { BuildLog.append("=== \(appName) (\(platform.rawValue)) — \(Date().formatted()) ===", to: log) }
        let root = folderURL
        let devRoot = projectsFolderURL ?? root.deletingLastPathComponent()
        let blocked = PromptActivity.blocksCompilation(
            activePromptProjects,
            names: [appName, scheme, project?.deletingPathExtension().lastPathComponent].compactMap { $0 },
            bundleIdentifier: bundleIdentifier ?? "")
        let task = Task {
            if blocked { throw IPARebuilder.RebuildError.promptRunning(appName) }
            return try await IPARebuilder.rebuild(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                project: project,
                scheme: scheme,
                devRoot: devRoot,
                ipaRoot: root,
                platform: platform,
                log: log,
                progress: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.rebuildStatus = message
                        if managesJob { self.updateJob(onlyIfRunning: true) { $0.step = message } }
                        onStep?(message)
                    }
                }
            )
        }
        activeBuild = task
        if cancelledJobID == ownerID { task.cancel() }
        var export: URL?
        do {
            export = try await task.value
        } catch {
            let cancelled = cancelledJobID == ownerID
            let message = cancelled ? String(localized: "Compilation annulée.") : error.localizedDescription
            failure = message
            if let log { BuildLog.append(message, to: log) }
            if reportsError, !cancelled { rebuildError = message }
            if managesJob {
                updateJob {
                    $0.state = cancelled ? "cancelled" : "failed"
                    $0.step = cancelled ? message : $0.step
                    $0.error = cancelled ? nil : message
                }
            }
        }
        activeBuild = nil
        if let export {
            await removeBuilds(supersededBy: export, log: log)
            // Annoncée une fois la liste à jour, pour que les clients la relisent sans les anciennes releases.
            if managesJob { updateJob { $0.state = "succeeded"; $0.step = String(localized: "Terminé") } }
        } else {
            await refresh()
        }
        rebuildingBundleID = nil
        rebuildStatus = nil
        return failure
    }

    /// Après une compilation réussie : supprime définitivement les anciennes releases de la même app.
    func removeBuilds(supersededBy export: URL, log: URL?) async {
        await refresh()
        guard let folderURL else { return }
        let obsolete = ObsoleteBuilds.folders(in: builds, supersededBy: export, root: folderURL)
        guard !obsolete.isEmpty else { return }
        let failures = await Task.detached {
            obsolete.compactMap { folder in
                do {
                    try FileManager.default.removeItem(at: folder)
                    return nil
                } catch {
                    return "\(folder.lastPathComponent) : \(error.localizedDescription)"
                }
            }
        }.value as [String]
        if let log {
            let names = obsolete.map(\.lastPathComponent).joined(separator: ", ")
            BuildLog.append("Anciennes releases supprimées : \(names)", to: log)
            for failure in failures { BuildLog.append("Suppression impossible : \(failure)", to: log) }
        }
        await refresh()
    }

    /// Copie une release macOS dans /Applications en remplaçant la version déjà installée.
    /// Si c'est l'app en cours d'exécution (ServeIPA lui-même), l'installation passe par le script détaché
    /// qui relance la nouvelle version.
    func installInApplications(_ build: IPABuild) async {
        guard build.platform == .macOS else { return }
        if let error = await install(build) {
            installMessage = String(localized: "Installation impossible : \(error)")
        } else if postponedApps.contains(build.name) {
            installMessage = String(localized: "« \(build.name) » est ouverte ou occupée : rien n’a été modifié. Quittez-la puis recommencez.")
        } else if !isRunningApp(build) {
            installMessage = String(localized: "« \(build.name) » \(build.version) (\(build.build)) est installée dans /Applications.")
        }
    }

    private func applicationsDestination(for build: IPABuild) -> URL {
        URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appending(path: build.fileURL.lastPathComponent, directoryHint: .isDirectory)
    }

    private func isRunningApp(_ build: IPABuild) -> Bool {
        applicationsDestination(for: build).standardizedFileURL == SelfUpdater.runningApp
    }

    /// Retourne nil en cas de succès, sinon le message d'erreur.
    private func install(_ build: IPABuild) async -> String? {
        let destination = applicationsDestination(for: build)
        if isRunningApp(build) {
            do {
                let jobID = currentJob.flatMap { $0.state == "running" ? $0.id : nil } ?? UUID().uuidString
                try await relaunch(with: build.fileURL, to: destination, jobID: jobID)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        let source = build.fileURL
        // Instances ouvertes depuis /Applications, relevées avant le remplacement.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: build.bundleIdentifier).filter {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path
                == destination.resolvingSymlinksInPath().standardizedFileURL.path
        }
        postponedApps.removeAll { $0 == build.name }
        // L'app quitte avant d'être remplacée ; si elle reste ouverte ou travaille, rien n'est modifié.
        if !running.isEmpty {
            let pids = running.map(\.processIdentifier)
            let identifier = build.bundleIdentifier
            let busy = await Task.detached {
                BusyApp.isBusy(bundleIdentifier: identifier, pids: pids, processList: BusyApp.processList())
            }.value
            if busy {
                postponedApps.append(build.name)
                return nil
            }
            if await !quit(running) {
                postponedApps.append(build.name)
                return nil
            }
        }
        var failure: String?
        do {
            try await Task.detached { try Self.copyApp(source, to: destination) }.value
            installRevision += 1
        } catch {
            failure = error.localizedDescription
        }
        // Rouvre la nouvelle version, ou l'ancienne restaurée après un échec.
        if !running.isEmpty { await launch(destination) }
        return failure
    }

    /// Demande aux instances de quitter, sans jamais les forcer. Faux si l'une d'elles reste ouverte.
    private func quit(_ instances: [NSRunningApplication]) async -> Bool {
        instances.forEach { _ = $0.terminate() }
        let deadline = Date().addingTimeInterval(8)
        while instances.contains(where: { !$0.isTerminated }) {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    private func launch(_ app: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    nonisolated static func executableDate(_ app: URL) -> Date? {
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any],
              let name = info["CFBundleExecutable"] as? String else { return nil }
        let path = app.appending(path: "Contents/MacOS/\(name)").path
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Vrai si l'app de /Applications a le même identifiant, la même version et le même build que cette release macOS,
    /// et n'a pas été compilée avant elle.
    nonisolated static func isInstalledInApplications(_ build: IPABuild) -> Bool {
        guard build.platform == .macOS else { return false }
        let app = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appending(path: build.fileURL.lastPathComponent, directoryHint: .isDirectory)
        let plist = app.appending(path: "Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { return false }
        return info["CFBundleIdentifier"] as? String == build.bundleIdentifier
            && info["CFBundleShortVersionString"] as? String ?? "" == build.version
            && info["CFBundleVersion"] as? String == build.build
            && !isCompiled(app, before: build.builtAt)
    }

    nonisolated private static func isCompiled(_ app: URL, before release: Date?) -> Bool {
        guard let release, let installed = executableDate(app) else { return false }
        return release.timeIntervalSince(installed) > 5
    }

    /// Dernières releases macOS de chaque app qui ne sont pas (ou pas à jour) dans /Applications.
    var missingInstallBuilds: [IPABuild] {
        _ = installRevision // relit /Applications après chaque installation
        return Dictionary(grouping: builds.filter { $0.platform == .macOS }, by: \.bundleIdentifier)
            .values.compactMap { group in
                group.max { ($0.folderDate ?? $0.folderName, Int($0.build) ?? -1) < ($1.folderDate ?? $1.folderName, Int($1.build) ?? -1) }
            }
            .filter { !Self.isInstalledInApplications($0) }
            .sorted { $0.name < $1.name }
    }

    /// Copie dans /Applications les dernières releases macOS manquantes. ServeIPA lui-même passe en dernier,
    /// car son installation relance l'app.
    @discardableResult
    func installMissingReleases() async -> (installed: Int, failures: [String]) {
        let targets = missingInstallBuilds.sorted { !isRunningApp($0) && isRunningApp($1) }
        var installed = 0
        var failures: [String] = []
        postponedApps = []
        for build in targets {
            // Relancer ServeIPA viderait la file : son installation attend qu'elle soit vide.
            if isRunningApp(build), !pendingJobs.isEmpty { continue }
            if let error = await install(build) {
                failures.append("\(build.name) : \(error)")
            } else if !postponedApps.contains(build.name) {
                installed += 1
            }
        }
        if !failures.isEmpty {
            installMessage = String(localized: "Installation impossible :\n\(failures.joined(separator: "\n"))")
        } else if installed > 0 {
            installMessage = String(localized: "\(installed) app(s) installée(s) dans /Applications.")
        }
        if !postponedApps.isEmpty {
            let names = postponedApps.formatted()
            installMessage = [installMessage, String(localized: "Reportées (ouvertes ou occupées) : \(names).")]
                .compactMap { $0 }.joined(separator: "\n")
        }
        return (installed, failures)
    }

    /// Recompile les apps dépassées (si `rebuild`), supprime les anciennes versions (si `clean`),
    /// puis copie dans /Applications les releases manquantes.
    /// Publie un job « maintenance » que les clients suivent via `GET /api/v1/builds`.
    func runMaintenance(rebuild requested: Bool?, clean: Bool, jobID: String = UUID().uuidString) async {
        guard !isRunningMaintenance else { return }
        isRunningMaintenance = true
        defer { isRunningMaintenance = false }
        let job = RebuildJob(id: jobID, app: String(localized: "Baguette magique"), platform: "Mac", state: "running",
                             step: String(localized: "Préparation…"), error: nil, startedAt: Date(), kind: "maintenance")
        beginJob(job)

        // Sans choix imposé, on recompile si un projet est plus récent que sa release.
        if requested == nil { await updateNewerProjectBuilds() }
        let rebuild = requested ?? !outdatedBuilds.isEmpty
        let blockedNames = rebuild ? outdatedBuilds.filter { isCompilationBlocked($0) }.map(\.name) : []
        let rebuilt = rebuild ? outdatedBuilds.count - blockedNames.count : 0
        let oldBefore = oldBuildCount
        var failures: [String] = []
        var rebuildFailures = 0
        if rebuild {
            let rebuildErrors = await updateOutdatedBuilds(thenClean: clean)
            rebuildFailures = rebuildErrors.count
            failures += rebuildErrors
        } else if clean, cancelledJobID != jobID {
            updateJob { $0.step = String(localized: "Suppression des anciennes versions…") }
            await cleanOldVersions()
        }
        if cancelledJobID == jobID {
            updateJob { $0.state = "cancelled"; $0.step = String(localized: "Baguette magique annulée.") }
            return
        }
        updateJob { $0.step = String(localized: "Copie dans /Applications…") }
        let install = await installMissingReleases()
        failures += install.failures

        let removed = max(0, oldBefore + rebuilt - oldBuildCount)
        var summary = String(localized: "\(max(0, rebuilt - rebuildFailures)) recompilée(s), \(removed) ancienne(s) version(s) supprimée(s), \(install.installed) copiée(s) dans /Applications.")
        if !postponedApps.isEmpty {
            let names = postponedApps.formatted()
            summary += " " + String(localized: "Reportées (ouvertes ou occupées) : \(names).")
        }
        if !blockedNames.isEmpty {
            summary += " " + String(localized: "Non recompilées (prompt rClaude en cours) : \(blockedNames.formatted()).")
        }
        updateJob {
            $0.step = summary
            if failures.isEmpty {
                $0.state = "succeeded"
            } else {
                $0.state = "failed"
                $0.error = failures.joined(separator: "\n")
            }
        }
    }

    /// Met en file la maintenance demandée par un client distant ; retourne l'identifiant du job.
    func startRemoteMaintenance() -> String? {
        enqueue(app: String(localized: "Baguette magique"), platform: "Mac", kind: "maintenance",
                key: "maintenance") { [weak self] jobID in
            await self?.runMaintenance(rebuild: nil, clean: true, jobID: jobID)
        }
    }

    /// Remplace `destination` par une copie de `source` ; l'ancienne version est restaurée en cas d'échec.
    nonisolated private static func copyApp(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let backup = destination.appendingPathExtension("ancienne")
        try? fileManager.removeItem(at: backup)
        let hadPrevious = fileManager.fileExists(atPath: destination.path)
        if hadPrevious { try fileManager.moveItem(at: destination, to: backup) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            let message = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                    NSLocalizedDescriptionKey: String(data: message, encoding: .utf8) ?? "ditto"
                ])
            }
            try? fileManager.removeItem(at: backup)
        } catch {
            try? fileManager.removeItem(at: destination)
            if hadPrevious { try? fileManager.moveItem(at: backup, to: destination) }
            throw error
        }
    }

    func delete(_ build: IPABuild) {
        do {
            try removeBuildDirectory(build)
        } catch {
            serverState = .failed(error.localizedDescription)
        }
    }

    /// Supprime le dossier d'export de l'IPA (sous-dossier direct ou non du dossier choisi, jamais la racine).
    /// Utilisé par l'app Mac et par l'API (`DELETE /api/v1/apps`).
    func removeBuildDirectory(_ build: IPABuild) throws {
        guard let folderURL else { throw DeleteError.unsafeDirectory }
        let rootURL = folderURL.standardizedFileURL
        let buildDirectoryURL = build.fileURL.deletingLastPathComponent().standardizedFileURL
        guard buildDirectoryURL != rootURL,
              buildDirectoryURL.pathComponents.starts(with: rootURL.pathComponents) else {
            throw DeleteError.unsafeDirectory
        }

        try FileManager.default.removeItem(at: buildDirectoryURL)
        builds.removeAll { $0.fileURL.deletingLastPathComponent().standardizedFileURL == buildDirectoryURL }
        server?.update(builds: builds, rootURL: folderURL, publicURL: serverURL)
        Task { await refresh() }
    }

    enum DeleteError: LocalizedError {
        case unsafeDirectory

        var errorDescription: String? {
            String(localized: "Le répertoire de cet IPA ne peut pas être supprimé en toute sécurité.")
        }
    }

    func startServer() async {
        guard let folderURL else {
            serverState = .failed(String(localized: "Choisissez d’abord un dossier."))
            return
        }
        guard serverState != .running && serverState != .starting else { return }
        serverState = .starting

        do {
            let publicURL = try await Tailscale.publicURL()
            let newServer = try OTAServer(port: port)
            newServer.update(builds: builds, rootURL: folderURL, publicURL: publicURL)
            newServer.deleteHandler = { [weak self] build in
                try await MainActor.run { [weak self] in
                    guard let self else { throw DeleteError.unsafeDirectory }
                    try self.removeBuildDirectory(build)
                }
            }
            newServer.rebuildHandler = { [weak self] build in
                await self?.startRemoteRebuild(build)
            }
            newServer.gitHandler = { [weak self] build, message, push in
                await self?.runGitAction(build, message: message, push: push)
                    ?? GitActionResult(succeeded: false, message: "ServeIPA n’est pas disponible.")
            }
            newServer.maintenanceHandler = { [weak self] in
                await self?.startRemoteMaintenance()
            }
            newServer.projectsScanHandler = { [weak self] in
                await self?.remoteProjectsJSON()
            }
            newServer.projectAddHandler = { [weak self] id, platform in
                await self?.startRemoteAddProject(id: id, platform: platform) ?? .busy
            }
            newServer.serverUpdateHandler = { [weak self] in
                await self?.startRemoteServerUpdate()
            }
            newServer.cancelHandler = { [weak self] id in
                await self?.cancelJob(id) ?? false
            }
            newServer.setRebuildJob(currentJob)
            newServer.setJobs(queue: pendingJobs.map(\.job), history: jobHistory)
            newServer.setServerUpdate(serverUpdateDetail)
            newServer.setProjectBuilds(newerProjectBuilds)
            newServer.setProjectGitDates(projectGitDates)
            server = newServer
            try newServer.start()
            try await Tailscale.serve(port: port)
            server = newServer
            serverURL = publicURL
            serverState = .running
        } catch {
            server?.stop()
            server = nil
            serverState = .failed(error.localizedDescription)
        }
    }

    func stopServer() async {
        server?.stop()
        server = nil
        await Tailscale.stop()
        serverState = .stopped
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            serverState = .failed(error.localizedDescription)
        }
    }

    func copyServerURL() {
        guard let serverURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serverURL.absoluteString, forType: .string)
    }

    func openServerURL() {
        guard let serverURL else { return }
        NSWorkspace.shared.open(serverURL)
    }

    /// Appelé une fois au lancement de l'app, indépendamment de ses fenêtres.
    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refresh()
        // Vrai aussi quand le script d'installation le passe en argument de lancement.
        let resumesAfterUpdate = UserDefaults.standard.bool(forKey: DefaultsKey.startServerAfterUpdate)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.startServerAfterUpdate)
        resolvePendingUpdate()
        // Boucle à part : une compilation longue ne doit pas figer l'indicateur.
        Task { await watchPrompts() }
        if startServerAutomatically || resumesAfterUpdate {
            await startServer()
        }
        await autoRefresh()
    }

    /// Relève toutes les 3 secondes les prompts rClaude en cours.
    private func watchPrompts() async {
        while !Task.isCancelled {
            let projects = await Task.detached { PromptActivity.projects(in: PromptActivity.commands()) }.value
            if projects != activePromptProjects { activePromptProjects = projects }
            server?.setActivePrompts(projects)
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Réanalyse le dossier toutes les 5 secondes jusqu'à l'annulation de la tâche.
    private func autoRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if !isScanning {
                await refresh()
            }
            // La recherche d'une mise à jour lit toutes les sources : pas à chaque tour.
            if Date().timeIntervalSince(lastUpdateCheck) >= 10 {
                lastUpdateCheck = Date()
                await checkForServerUpdate()
            }
            await runNightlyBuildIfDue()
        }
    }

    /// Lance la maintenance complète (baguette magique) une fois par nuit, pendant l'heure de 1 h,
    /// si l'option est activée et que le serveur tourne.
    private func runNightlyBuildIfDue(now: Date = Date()) async {
        guard nightlyBuild, serverState == .running,
              Calendar.current.component(.hour, from: now) == 1,
              !isScanning, !isBusy, pendingJobs.isEmpty else { return }
        let today = Calendar.current.startOfDay(for: now)
        if let last = UserDefaults.standard.object(forKey: DefaultsKey.lastNightlyRun) as? Date,
           Calendar.current.isDate(last, inSameDayAs: today) { return }
        // Noté avant de commencer : une recompilation de ServeIPA lui-même relance l'app.
        UserDefaults.standard.set(now, forKey: DefaultsKey.lastNightlyRun)
        await runMaintenance(rebuild: nil, clean: true)
    }

    private func restoreFolder() {
        guard let bookmark = UserDefaults.standard.data(forKey: DefaultsKey.folderBookmark) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }
        folderURL = url
        isAccessingSecurityScopedFolder = url.startAccessingSecurityScopedResource()
        if stale {
            saveFolder(url)
        }
    }

    private func saveFolder(_ url: URL) {
        if isAccessingSecurityScopedFolder {
            folderURL?.stopAccessingSecurityScopedResource()
        }
        folderURL = url
        isAccessingSecurityScopedFolder = url.startAccessingSecurityScopedResource()
        if let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: DefaultsKey.folderBookmark)
        }
    }

    /// Supprime les dossiers d'export des builds au-delà des `keep` plus récents de chaque app.
    /// Un dossier n'est supprimé que si aucun build conservé ne s'y trouve, et jamais la racine.
    /// Retourne le nombre de dossiers supprimés.
    nonisolated private static func pruneOldBuilds(_ builds: [IPABuild], keep: Int, rootURL: URL) -> Int {
        let root = rootURL.standardizedFileURL
        let directory = { (build: IPABuild) in build.fileURL.deletingLastPathComponent().standardizedFileURL }
        let newestFirst = { (a: IPABuild, b: IPABuild) -> Bool in
            let left = (a.folderDate ?? a.folderName, Int(a.build) ?? -1)
            let right = (b.folderDate ?? b.folderName, Int(b.build) ?? -1)
            return left > right
        }
        var kept: Set<URL> = []
        var candidates: Set<URL> = []
        for group in Dictionary(grouping: builds, by: { "\($0.platform.rawValue)/\($0.bundleIdentifier)" }).values {
            let sorted = group.sorted(by: newestFirst)
            sorted.prefix(keep).forEach { kept.insert(directory($0)) }
            sorted.dropFirst(keep).forEach { candidates.insert(directory($0)) }
        }
        var removed = 0
        for url in candidates.subtracting(kept)
        where url != root && url.pathComponents.starts(with: root.pathComponents) {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    nonisolated private static func scan(_ rootURL: URL) -> (builds: [IPABuild], issues: [ScanIssue]) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isHiddenKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ([], [ScanIssue(path: rootURL.path, message: String(localized: "Dossier inaccessible"))])
        }

        var builds: [IPABuild] = []
        var issues: [ScanIssue] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "app", url.deletingLastPathComponent() != rootURL {
                do {
                    let metadata = try IPAMetadataReader.readApp(url)
                    let relative = String(url.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let folder = url.deletingLastPathComponent().lastPathComponent
                    let details = IPABuild.folderDetails(folder)
                    builds.append(IPABuild(
                        id: relative,
                        fileURL: url,
                        relativePath: relative,
                        name: metadata.name,
                        bundleIdentifier: metadata.bundleIdentifier,
                        version: metadata.version,
                        build: metadata.build,
                        platforms: metadata.platforms,
                        folderName: folder,
                        folderDate: details.date,
                        size: IPAMetadataReader.directorySize(url),
                        urlSchemes: [],
                        minimumOSVersion: metadata.minimumOSVersion,
                        iconEntry: metadata.iconEntry,
                        platform: .macOS,
                        builtAt: Self.executableDate(url)
                    ))
                } catch {
                    issues.append(ScanIssue(path: url.lastPathComponent, message: error.localizedDescription))
                }
                continue
            }
            guard url.pathExtension.lowercased() == "ipa",
                  url.deletingLastPathComponent() != rootURL else { continue }
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { continue }
                let metadata = try IPAMetadataReader.read(url)
                let relative = String(url.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let folder = url.deletingLastPathComponent().lastPathComponent
                let details = IPABuild.folderDetails(folder)
                builds.append(IPABuild(
                    id: relative,
                    fileURL: url,
                    relativePath: relative,
                    name: metadata.name,
                    bundleIdentifier: metadata.bundleIdentifier,
                    version: metadata.version,
                    build: metadata.build,
                    platforms: metadata.platforms,
                    folderName: folder,
                    folderDate: details.date,
                    size: Int64(values.fileSize ?? 0),
                    urlSchemes: metadata.urlSchemes,
                    minimumOSVersion: metadata.minimumOSVersion,
                    iconEntry: metadata.iconEntry
                ))
            } catch {
                issues.append(ScanIssue(path: url.lastPathComponent, message: error.localizedDescription))
            }
        }

        builds.sort {
            ($0.folderDate ?? $0.folderName, $0.name) > ($1.folderDate ?? $1.folderName, $1.name)
        }
        return (builds, issues)
    }
}

enum IPAMetadataReader {
    struct Metadata {
        let name: String
        let bundleIdentifier: String
        let version: String
        let build: String
        let platforms: [String]
        let urlSchemes: [String]
        let minimumOSVersion: String?
        let iconEntry: String?
    }

    nonisolated static func read(_ ipaURL: URL) throws -> Metadata {
        let listing = try runUnzip(arguments: ["-Z1", ipaURL.path])
        let entries = listing.split(separator: "\n").map(String.init)
        let pattern = #"^Payload/[^/]+\.app/Info\.plist$"#
        let candidates = entries.filter {
            $0.range(of: pattern, options: .regularExpression) != nil
        }
        guard candidates.count == 1, let plistPath = candidates.first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Info.plist principal introuvable ou ambigu")
            ])
        }

        let data = try runUnzipData(arguments: ["-p", ipaURL.path, plistPath])
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundle = info["CFBundleIdentifier"] as? String,
              let build = info["CFBundleVersion"] as? String else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return Metadata(
            name: info["CFBundleDisplayName"] as? String
                ?? info["CFBundleName"] as? String
                ?? ipaURL.deletingPathExtension().lastPathComponent,
            bundleIdentifier: bundle,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: build,
            platforms: info["CFBundleSupportedPlatforms"] as? [String] ?? [],
            urlSchemes: (info["CFBundleURLTypes"] as? [[String: Any]] ?? [])
                .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] },
            minimumOSVersion: info["MinimumOSVersion"] as? String,
            iconEntry: iconEntry(entries: entries, info: info)
        )
    }

    /// Lit les métadonnées d'une app macOS (bundle .app exporté).
    nonisolated static func readApp(_ appURL: URL) throws -> Metadata {
        let data = try Data(contentsOf: appURL.appending(path: "Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundle = info["CFBundleIdentifier"] as? String,
              let build = info["CFBundleVersion"] as? String else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Icône déclarée (CFBundleIconFile), sinon un .icns, sinon un PNG « icon » dans Resources :
        // une icône compilée dans Assets.car seule n'est pas lisible hors d'Apple.
        let resources = appURL.appending(path: "Contents/Resources")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []).sorted()
        var icon: String?
        if let file = info["CFBundleIconFile"] as? String, !file.isEmpty {
            let name = file.hasSuffix(".icns") ? file : file + ".icns"
            if files.contains(name) { icon = "Contents/Resources/" + name }
        }
        if icon == nil,
           let found = files.first(where: { $0.hasSuffix(".icns") })
            ?? files.first(where: { $0.hasSuffix(".png") && $0.localizedCaseInsensitiveContains("icon") }) {
            icon = "Contents/Resources/" + found
        }
        // Icône Icon Composer / Assets.car seule : on demandera son rendu au système.
        if icon == nil { icon = workspaceIconEntry }
        return Metadata(
            name: info["CFBundleDisplayName"] as? String
                ?? info["CFBundleName"] as? String
                ?? appURL.deletingPathExtension().lastPathComponent,
            bundleIdentifier: bundle,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: build,
            platforms: info["CFBundleSupportedPlatforms"] as? [String] ?? ["MacOSX"],
            urlSchemes: [],
            minimumOSVersion: info["LSMinimumSystemVersion"] as? String,
            iconEntry: icon
        )
    }

    /// Taille cumulée des fichiers d'un bundle.
    nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Choisit la meilleure icône PNG à la racine du bundle : d'abord les fichiers déclarés
    /// dans CFBundleIconFiles, sinon les PNG dont le nom contient « icon ». Préfère la plus grande.
    nonisolated private static func iconEntry(entries: [String], info: [String: Any]) -> String? {
        let pngs = entries.filter {
            $0.range(of: #"^Payload/[^/]+\.app/[^/]+\.png$"#, options: .regularExpression) != nil
        }
        var prefixes = info["CFBundleIconFiles"] as? [String] ?? []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let primary = (info[key] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
            prefixes += primary?["CFBundleIconFiles"] as? [String] ?? []
        }
        let fileName = { (path: String) in (path as NSString).lastPathComponent }
        let declared = pngs.filter { path in prefixes.contains { fileName(path).hasPrefix($0) } }
        let pool = declared.isEmpty
            ? pngs.filter { fileName($0).localizedCaseInsensitiveContains("icon") }
            : declared
        func score(_ path: String) -> Int {
            let name = fileName(path)
            if name.contains("1024") { return 5 }
            if name.contains("@3x") { return 4 }
            if name.contains("@2x") { return name.contains("~ipad") ? 2 : 3 }
            return 1
        }
        return pool.max { score($0) < score($1) }
    }

    /// Extrait l'icône de l'IPA et la réencode en PNG standard (les PNG iOS sont au format
    /// optimisé « CgBI », que ImageIO sait décoder), réduite à `maxPixels`.
    nonisolated static func iconPNG(ipaURL: URL, entry: String, maxPixels: Int = 180) -> Data? {
        guard let raw = try? runUnzipData(arguments: ["-p", ipaURL.path, entry]) else { return nil }
        return pngThumbnail(raw, maxPixels: maxPixels)
    }

    /// Valeur d'`iconEntry` signifiant « pas de fichier d'icône : utiliser celle que macOS affiche pour l'app ».
    nonisolated static let workspaceIconEntry = "workspace-icon"

    /// Icône d'une app macOS (.icns ou PNG dans le bundle, sinon rendu du système), convertie en PNG.
    nonisolated static func iconPNG(appURL: URL, entry: String, maxPixels: Int = 180) -> Data? {
        if entry == workspaceIconEntry {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            guard let tiff = icon.tiffRepresentation else { return nil }
            return pngThumbnail(tiff, maxPixels: maxPixels)
        }
        guard let raw = try? Data(contentsOf: appURL.appending(path: entry)) else { return nil }
        return pngThumbnail(raw, maxPixels: maxPixels)
    }

    nonisolated private static func pngThumbnail(_ raw: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    nonisolated private static func runUnzip(arguments: [String]) throws -> String {
        let data = try runUnzipData(arguments: arguments)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }

    nonisolated private static func runUnzipData(arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }
}

private enum Tailscale {
    static func publicURL() async throws -> URL {
        let data = try await run(arguments: ["status", "--json"])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let selfInfo = object?["Self"] as? [String: Any]
        guard let dnsName = selfInfo?["DNSName"] as? String else {
            throw TailscaleError.missingDNSName
        }
        let hostname = dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let url = URL(string: "https://\(hostname)") else {
            throw TailscaleError.missingDNSName
        }
        return url
    }

    static func serve(port: UInt16) async throws {
        _ = try await run(arguments: ["serve", "--bg", String(port)])
    }

    static func stop() async {
        _ = try? await run(arguments: ["serve", "reset"])
    }

    private static func run(arguments: [String]) async throws -> Data {
        try await Task.detached {
            try runSync(arguments: arguments)
        }.value
    }

    nonisolated private static func runSync(arguments: [String]) throws -> Data {
        let candidates = [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TailscaleError.cliNotFound
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors

        try process.run()

        // Lire les deux pipes en parallèle sur des threads séparés : les lire
        // séquentiellement (stdout puis stderr) peut bloquer indéfiniment ou
        // tronquer la sortie si l'un des deux tampons se remplit avant l'autre.
        let outputHandle = output.fileHandleForReading
        let errorsHandle = errors.fileHandleForReading
        let group = DispatchGroup()
        var data = Data()
        var errorData = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            data = outputHandle.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData = errorsHandle.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? String(localized: "Erreur Tailscale")
            throw TailscaleError.commandFailed(message)
        }
        return data
    }

    enum TailscaleError: LocalizedError {
        case cliNotFound
        case missingDNSName
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound: String(localized: "La commande Tailscale est introuvable.")
            case .missingDNSName: String(localized: "Le nom MagicDNS Tailscale est introuvable.")
            case .commandFailed(let message): message
            }
        }
    }
}

/// N'active dans le sélecteur que les projets Xcode et les dossiers (pour naviguer).
private final class XcodeProjectPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if url.pathExtension == "xcodeproj" { return true }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return isDirectory && !isPackage
    }
}
