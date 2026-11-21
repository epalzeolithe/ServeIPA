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

    private enum DefaultsKey {
        static let folderBookmark = "ipaFolderBookmark"
        static let startServerAutomatically = "startServerAutomatically"
        static let keepBuildsPerApp = "keepBuildsPerApp"
        static let projectsBookmark = "projectsFolderBookmark"
    }

    var builds: [IPABuild] = []
    var scanIssues: [ScanIssue] = []
    var serverState: ServerState = .stopped
    var serverURL: URL?
    var selectedBuildID: String?
    var folderURL: URL?
    var isScanning = false
    /// Identifiant de bundle de l'app en cours de recompilation, son étape et la dernière erreur.
    var rebuildingBundleID: String?
    var rebuildStatus: String?
    var rebuildError: String?
    private var currentJob: RebuildJob?
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

    /// Nombre de builds conservés par app (identifiant de bundle). 0 = nettoyage désactivé.
    var keepBuildsPerApp: Int {
        didSet {
            UserDefaults.standard.set(keepBuildsPerApp, forKey: DefaultsKey.keepBuildsPerApp)
            Task { await refresh() }
        }
    }

    let port: UInt16 = 8765
    private var server: OTAServer?
    private var isAccessingSecurityScopedFolder = false

    init() {
        UserDefaults.standard.register(defaults: [DefaultsKey.startServerAutomatically: true])
        startServerAutomatically = UserDefaults.standard.bool(forKey: DefaultsKey.startServerAutomatically)
        keepBuildsPerApp = UserDefaults.standard.integer(forKey: DefaultsKey.keepBuildsPerApp)
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
        projectAddStates = [:]
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

    /// Recompile ServeIPA depuis son projet (macOS, Release), puis le remplace et le relance.
    func updateServeIPA() async {
        guard rebuildingBundleID == nil, !isAddingProjects else {
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

        let bundleID = Bundle.main.bundleIdentifier ?? ""
        rebuildingBundleID = "ServeIPA"
        rebuildStatus = String(localized: "Recherche du projet…")
        rebuildError = nil
        do {
            let project = try await Task.detached {
                try IPARebuilder.findProject(bundleIdentifier: bundleID, appName: "ServeIPA", devRoot: devRoot, ipaRoot: folderURL)
            }.value
            let export = try await IPARebuilder.rebuild(
                bundleIdentifier: bundleID, appName: "ServeIPA", project: project,
                devRoot: devRoot, ipaRoot: folderURL, platform: .macOS,
                progress: { message in Task { @MainActor in self.rebuildStatus = message } }
            )
            let app = try SelfUpdater.exportedApp(in: export)
            rebuildStatus = String(localized: "Installation et relance…")
            await stopServer()
            try SelfUpdater.installAndRelaunch(app, to: destination)
        } catch {
            rebuildError = error.localizedDescription
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
        server?.update(builds: iosBuilds, rootURL: folderURL, publicURL: serverURL)
    }

    /// Seuls les IPA iOS sont proposés par le serveur OTA.
    private var iosBuilds: [IPABuild] { builds.filter { $0.platform == .iOS } }

    /// Nombre de builds qui ne sont pas le plus récent de leur app (par plateforme).
    var oldBuildCount: Int {
        builds.count - Set(builds.map { "\($0.platform.rawValue)/\($0.bundleIdentifier)" }).count
    }

    /// Supprime définitivement du disque toutes les anciennes versions, en ne gardant que le build le plus récent de chaque app.
    func cleanOldVersions() async {
        guard let folderURL, !isScanning else { return }
        let current = builds
        _ = await Task.detached {
            Self.pruneOldBuilds(current, keep: 1, rootURL: folderURL)
        }.value
        await refresh()
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

    /// Lance une recompilation demandée par un client distant ; retourne l'identifiant du job, ou nil si le Mac est occupé.
    func startRemoteRebuild(_ build: IPABuild) -> String? {
        guard folderURL != nil, rebuildingBundleID == nil else { return nil }
        rebuildingBundleID = build.bundleIdentifier
        let id = UUID().uuidString
        Task {
            await runRebuild(label: build.bundleIdentifier, bundleIdentifier: build.bundleIdentifier,
                             appName: build.name, project: nil, platform: build.platform,
                             jobID: id, alreadyClaimed: true)
        }
        return id
    }

    private func updateJob(onlyIfRunning: Bool = false, _ change: (inout RebuildJob) -> Void) {
        guard var job = currentJob, !onlyIfRunning || job.state == "running" else { return }
        change(&job)
        currentJob = job
        server?.setRebuildJob(job)
    }

    /// Retourne nil en cas de succès, sinon le message d'erreur (affiché dans une alerte si `reportsError`).
    @discardableResult
    private func runRebuild(label: String, bundleIdentifier: String?, appName: String,
                            project: URL?, scheme: String? = nil, platform: IPABuild.Platform,
                            jobID: String = UUID().uuidString, alreadyClaimed: Bool = false,
                            reportsError: Bool = true, onStep: (@MainActor (String) -> Void)? = nil) async -> String? {
        guard let folderURL, alreadyClaimed || rebuildingBundleID == nil else {
            if alreadyClaimed { rebuildingBundleID = nil }
            return String(localized: "Une compilation est déjà en cours, ou le dossier des IPA n’est pas choisi.")
        }
        var failure: String?
        rebuildingBundleID = label
        rebuildStatus = nil
        rebuildError = nil
        let initial = RebuildJob(id: jobID, app: appName, platform: platform.rawValue, state: "running",
                                 step: String(localized: "Préparation…"), error: nil, startedAt: Date())
        currentJob = initial
        server?.setRebuildJob(initial)
        let root = folderURL
        do {
            _ = try await IPARebuilder.rebuild(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                project: project,
                scheme: scheme,
                devRoot: projectsFolderURL ?? root.deletingLastPathComponent(),
                ipaRoot: root,
                platform: platform,
                progress: { message in
                    Task { @MainActor in
                        self.rebuildStatus = message
                        self.updateJob(onlyIfRunning: true) { $0.step = message }
                        onStep?(message)
                    }
                }
            )
            updateJob { $0.state = "succeeded"; $0.step = String(localized: "Terminé") }
        } catch {
            failure = error.localizedDescription
            if reportsError { rebuildError = error.localizedDescription }
            updateJob { $0.state = "failed"; $0.error = error.localizedDescription }
        }
        rebuildingBundleID = nil
        rebuildStatus = nil
        await refresh()
        return failure
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
        server?.update(builds: iosBuilds, rootURL: folderURL, publicURL: serverURL)
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
            newServer.update(builds: iosBuilds, rootURL: folderURL, publicURL: publicURL)
            newServer.deleteHandler = { [weak self] build in
                try await MainActor.run {
                    guard let self else { throw DeleteError.unsafeDirectory }
                    try self.removeBuildDirectory(build)
                }
            }
            newServer.rebuildHandler = { [weak self] build in
                await MainActor.run { self?.startRemoteRebuild(build) }
            }
            newServer.setRebuildJob(currentJob)
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

    func startIfNeeded() async {
        await refresh()
        if startServerAutomatically {
            await startServer()
        }
        await autoRefresh()
    }

    /// Réanalyse le dossier toutes les 5 secondes jusqu'à l'annulation de la tâche.
    private func autoRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if !isScanning {
                await refresh()
            }
        }
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
                        platform: .macOS
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
        guard let raw = try? runUnzipData(arguments: ["-p", ipaURL.path, entry]),
              let source = CGImageSourceCreateWithData(raw as CFData, nil),
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
