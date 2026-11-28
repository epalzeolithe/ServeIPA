import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: IPAStore
    @State private var buildToDelete: IPABuild?
    @State private var showsCleanConfirmation = false
    @State private var platform: IPABuild.Platform = .macOS
    @State private var showsProjectScan = false
    @State private var searchText = ""

    /// Builds de la plateforme choisie qui correspondent à la recherche (nom, identifiant, version, build).
    private var visibleBuilds: [IPABuild] {
        let builds = store.builds.filter { $0.platform == platform }
        guard !searchText.isEmpty else { return builds }
        return builds.filter { (build: IPABuild) -> Bool in
            let fields: [String] = [build.name, build.displayName, build.bundleIdentifier, build.version, build.build]
            return fields.contains { (field: String) -> Bool in field.localizedStandardContains(searchText) }
        }
    }

    private func buildCount(for platform: IPABuild.Platform) -> Int {
        store.builds.filter { $0.platform == platform }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ServerHeader(
                state: store.serverState,
                serverURL: store.serverURL,
                isScanning: store.isScanning,
                startAction: { Task { await store.startServer() } },
                stopAction: { Task { await store.stopServer() } }
            )
            Divider()
            Picker("Plateforme", selection: $platform) {
                ForEach(IPABuild.Platform.allCases, id: \.self) { platform in
                    Text("\(platform.rawValue) (\(buildCount(for: platform)))")
                        .tag(platform)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)
            BuildList(
                builds: visibleBuilds,
                platform: platform,
                searchText: searchText,
                selection: $store.selectedBuildID,
                oldBuildCount: store.oldBuildCount,
                newerProjectBuilds: store.newerProjectBuilds,
                activePromptProjects: store.activePromptProjects,
                installRevision: store.installRevision,
                rebuildingBundleID: store.rebuildingBundleID,
                rebuildStatus: store.rebuildStatus,
                rebuildAction: { build in Task { await store.rebuild(build) } },
                installAction: { build in Task { await store.installInApplications(build) } },
                deleteAction: { buildToDelete = $0 },
                cleanAction: { showsCleanConfirmation = true }
            )
        }
        .frame(minWidth: 720, minHeight: 460)
        .searchable(text: $searchText, prompt: "App, version ou identifiant")
        .toolbar {
            ToolbarItem {
                Button("Scanner les projets Xcode…", systemImage: "magnifyingglass") {
                    showsProjectScan = true
                }
                .help("Chercher les projets Xcode d’un dossier et ajouter leurs apps")
            }
            if platform == .macOS {
                ToolbarItem {
                    Button("Ajouter une app depuis son projet Xcode…", systemImage: "plus") {
                        Task { await store.addApp(platform: .macOS) }
                    }
                    .disabled(store.folderURL == nil || store.rebuildingBundleID != nil)
                }
            }
            ToolbarItem {
                Button("Choisir le dossier…", systemImage: "folder") {
                    store.chooseFolder()
                }
            }
            ToolbarItem {
                Button("Actualiser", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .disabled(store.folderURL == nil || store.isScanning)
            }
            ToolbarItem {
                Button("Mettre à jour et nettoyer", systemImage: "wand.and.sparkles") {
                    showsCleanConfirmation = true
                }
                .help("Recompiler les apps dont le projet est plus récent, supprimer les anciennes versions, copier les releases manquantes dans /Applications, puis commiter et pousser les projets")
                .disabled(store.builds.isEmpty
                          || store.isScanning
                          || store.rebuildingBundleID != nil)
            }
        }
        .sheet(isPresented: $showsProjectScan) {
            ProjectScanView(store: store)
        }
        .alert("Recompilation impossible", isPresented: Binding(
            get: { store.rebuildError != nil },
            set: { if !$0 { store.rebuildError = nil } }
        )) {
            Button("OK") { store.rebuildError = nil }
        } message: {
            Text(store.rebuildError ?? "")
        }
        .alert("Installation dans /Applications", isPresented: Binding(
            get: { store.installMessage != nil },
            set: { if !$0 { store.installMessage = nil } }
        )) {
            Button("OK") { store.installMessage = nil }
        } message: {
            Text(store.installMessage ?? "")
        }
        .confirmationDialog(
            store.outdatedBuilds.isEmpty && store.oldBuildCount == 0
                ? store.missingInstallBuilds.isEmpty ? "Commiter et pousser les projets ?" : "Installer les releases manquantes ?"
                : store.outdatedBuilds.isEmpty ? "Supprimer toutes les anciennes versions ?" : "Mettre à jour et nettoyer ?",
            isPresented: $showsCleanConfirmation,
            titleVisibility: .visible
        ) {
            let outdated = store.outdatedBuilds.count
            let old = store.oldBuildCount
            let missing = store.missingInstallBuilds.count
            if outdated > 0 {
                // Le nettoyage est toujours fait après recompilation : le nouveau build rend l'ancienne release obsolète.
                Button("Recompiler \(outdated) app(s) puis nettoyer") {
                    Task { await store.runMaintenance(rebuild: true, clean: true, commitAndPush: true) }
                }
            }
            if old > 0 {
                Button("Supprimer \(old) ancien(s) build(s)", role: .destructive) {
                    Task { await store.runMaintenance(rebuild: false, clean: true, commitAndPush: true) }
                }
            }
            if outdated == 0 && old == 0 {
                Button(missing > 0 ? "Copier \(missing) app(s), commiter et pousser" : "Commit et push") {
                    Task { await store.runMaintenance(rebuild: false, clean: false, commitAndPush: true) }
                }
            }
        } message: {
            let names = store.outdatedBuilds.map { "\($0.name) (\($0.platform.rawValue))" }.formatted()
            let missing = store.missingInstallBuilds.map(\.name).formatted()
            let installNote = store.missingInstallBuilds.isEmpty
                ? ""
                : String(localized: " Les releases macOS manquantes dans /Applications seront ensuite copiées : \(missing).")
            if store.outdatedBuilds.isEmpty && store.oldBuildCount == 0 {
                if store.missingInstallBuilds.isEmpty {
                    Text("Chaque projet sera indexé en entier, commité et poussé.")
                } else {
                    Text("Releases macOS absentes ou différentes dans /Applications : \(missing). Chaque projet sera ensuite indexé en entier, commité et poussé.")
                }
            } else if store.outdatedBuilds.isEmpty {
                Text("Seul le build le plus récent de chaque app est conservé. Les dossiers des autres sont supprimés définitivement du disque.\(installNote) Chaque projet sera ensuite indexé en entier, commité et poussé.")
            } else {
                Text("Projets plus récents que leur release : \(names). Ils seront recompilés l’un après l’autre. Le nettoyage ne conserve ensuite que le build le plus récent de chaque app ; les autres dossiers sont supprimés définitivement.\(installNote) Chaque projet sera ensuite indexé en entier, commité et poussé.")
            }
        }
        .confirmationDialog(
            "Supprimer ce répertoire et son IPA ?",
            isPresented: Binding(
                get: { buildToDelete != nil },
                set: { if !$0 { buildToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: buildToDelete
        ) { build in
            Button("Supprimer définitivement", role: .destructive) {
                store.delete(build)
                buildToDelete = nil
            }
        } message: { build in
            Text("Le répertoire « \(build.folderName) » et tout son contenu seront supprimés définitivement du disque.")
        }
    }
}

private struct ServerHeader: View {
    let state: IPAStore.ServerState
    let serverURL: URL?
    let isScanning: Bool
    let startAction: () -> Void
    let stopAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.symbolName)
                .font(.title2)
                .foregroundStyle(state == .running ? .green : .secondary)
                .symbolEffect(.rotate, isActive: state == .starting)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.headline)
                if let serverURL {
                    Text(serverURL.absoluteString)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if case .failed(let message) = state {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("Le serveur utilise Tailscale Serve sur le port 8765.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isScanning {
                ProgressView()
                    .controlSize(.small)
            }
            if state == .running || state == .starting {
                Button("Arrêter", action: stopAction)
                    .disabled(state == .starting)
            } else {
                Button("Démarrer", action: startAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

/// Tous les builds d'une même app (même identifiant de bundle), du plus récent au plus ancien.
private struct BuildGroup: Identifiable {
    let id: String
    let builds: [IPABuild]
    var latest: IPABuild { builds[0] }
    var older: ArraySlice<IPABuild> { builds.dropFirst() }

    /// Regroupe en conservant l'ordre des builds (déjà trié du plus récent au plus ancien).
    static func grouping(_ builds: [IPABuild]) -> [BuildGroup] {
        var order: [String] = []
        var buckets: [String: [IPABuild]] = [:]
        for build in builds {
            if buckets[build.bundleIdentifier] == nil { order.append(build.bundleIdentifier) }
            buckets[build.bundleIdentifier, default: []].append(build)
        }
        return order.map { BuildGroup(id: $0, builds: buckets[$0] ?? []) }
    }
}

private struct BuildList: View {
    let builds: [IPABuild]
    let platform: IPABuild.Platform
    /// Recherche en cours : les groupes sont dépliés pour montrer tous les builds correspondants.
    let searchText: String
    @Binding var selection: String?
    let oldBuildCount: Int
    /// Numéro de build du projet Xcode, pour les releases dont le projet est plus récent.
    let newerProjectBuilds: [String: Int]
    let activePromptProjects: [String]
    let installRevision: Int
    let rebuildingBundleID: String?
    let rebuildStatus: String?
    let rebuildAction: (IPABuild) -> Void
    let installAction: (IPABuild) -> Void
    let deleteAction: (IPABuild) -> Void
    let cleanAction: () -> Void
    @State private var expandedGroups: Set<String> = []

    private var groups: [BuildGroup] { BuildGroup.grouping(builds) }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) || !searchText.isEmpty },
            set: { if $0 { expandedGroups.insert(id) } else { expandedGroups.remove(id) } }
        )
    }

    /// Lance l'app macOS exportée.
    private func launch(_ build: IPABuild) {
        NSWorkspace.shared.openApplication(at: build.fileURL, configuration: NSWorkspace.OpenConfiguration())
    }

    private func isCompilationBlocked(_ build: IPABuild) -> Bool {
        PromptActivity.blocksCompilation(activePromptProjects, names: [build.name, build.displayName],
                                         bundleIdentifier: build.bundleIdentifier)
    }

    private func row(for build: IPABuild, isLatest: Bool, olderCount: Int = 0) -> some View {
        BuildRow(build: build, isLatest: isLatest, olderCount: olderCount,
                 newerProjectBuild: isLatest ? newerProjectBuilds[build.id] : nil,
                 installRevision: installRevision,
                 isRunningPrompt: isLatest && PromptActivity.concerns(
                    activePromptProjects, names: [build.name, build.displayName],
                    bundleIdentifier: build.bundleIdentifier))
            .tag(build.id)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if build.platform == .macOS { launch(build) }
            })
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Supprimer", systemImage: "trash", role: .destructive) {
                    deleteAction(build)
                }
            }
            .contextMenu {
                if build.platform == .macOS {
                    Button("Ouvrir l’app", systemImage: "arrow.up.forward.app") { launch(build) }
                    Button("Copier dans /Applications", systemImage: "square.and.arrow.down") { installAction(build) }
                    Divider()
                }
                Button(build.platform == .macOS ? "Recompiler et exporter l’app" : "Recompiler et exporter l’IPA", systemImage: "hammer") {
                    rebuildAction(build)
                }
                .disabled(rebuildingBundleID != nil || isCompilationBlocked(build))
                Button("Afficher dans le Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([build.fileURL])
                }
                Divider()
                Button("Supprimer", systemImage: "trash", role: .destructive) {
                    deleteAction(build)
                }
            }
    }

    var body: some View {
        if builds.isEmpty {
            ContentUnavailableView(
                !searchText.isEmpty ? "Aucun résultat" : platform == .iOS ? "Aucun IPA" : "Aucune app macOS",
                systemImage: searchText.isEmpty ? "shippingbox" : "magnifyingglass",
                description: Text(!searchText.isEmpty
                    ? "Aucun build ne correspond à « \(searchText) »."
                    : platform == .iOS
                    ? "Choisissez un dossier contenant des IPA dans ses sous-dossiers."
                    : "Ajoutez une app avec le bouton + de la barre d’outils, ou exportez-la dans un sous-dossier.")
            )
        } else {
            List(selection: $selection) {
                ForEach(groups) { group in
                    if group.older.isEmpty {
                        row(for: group.latest, isLatest: true)
                    } else {
                        DisclosureGroup(isExpanded: expansionBinding(for: group.id)) {
                            ForEach(group.older) { build in row(for: build, isLatest: false) }
                        } label: {
                            row(for: group.latest, isLatest: true, olderCount: group.older.count)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let bundleID = rebuildingBundleID {
                        RebuildProgressCard(
                            appName: builds.first { $0.bundleIdentifier == bundleID }?.name ?? bundleID,
                            platform: platform,
                            status: rebuildStatus
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    Divider()
                    HStack(spacing: 4) {
                        Text("\(groups.count) apps")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("ServeIPA \(AppBuildInfo.current.summary)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.trailing, 8)
                        if let selected = builds.first(where: { $0.id == selection }) {
                            Button("Recompiler", systemImage: "hammer") {
                                rebuildAction(selected)
                            }
                            .disabled(rebuildingBundleID != nil || isCompilationBlocked(selected))
                            if selected.platform == .macOS {
                                Button("Copier dans /Applications", systemImage: "square.and.arrow.down") {
                                    installAction(selected)
                                }
                            }
                            Button("Afficher dans le Finder", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([selected.fileURL])
                            }
                            Button("Supprimer", systemImage: "trash", role: .destructive) {
                                deleteAction(selected)
                            }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(.bar)
                .animation(.smooth, value: rebuildingBundleID)
            }
        }
    }
}

/// Carte de progression d'une recompilation : app, plateforme et étape en cours.
private struct RebuildProgressCard: View {
    let appName: String
    let platform: IPABuild.Platform
    let status: String?

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recompilation de \(appName)")
                    .font(.subheadline.weight(.semibold))
                Text(status ?? "Préparation…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            Text(platform.rawValue)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.15), in: .capsule)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator)
        }
        .animation(.smooth, value: status)
        .accessibilityElement(children: .combine)
    }
}

private struct BuildRow: View {
    let build: IPABuild
    /// Build le plus récent de son app (ligne principale du groupe, avec icône et nom).
    let isLatest: Bool
    let olderCount: Int
    /// Numéro de build du projet Xcode s'il est plus récent que cette release.
    var newerProjectBuild: Int?
    /// Change après chaque installation dans /Applications pour forcer la relecture de l'app installée.
    var installRevision = 0
    /// rClaude exécute un prompt sur le projet de cette app.
    var isRunningPrompt = false

    var body: some View {
        HStack(spacing: 10) {
            if isLatest {
                BuildIconView(build: build)
            } else {
                Color.clear.frame(width: 36, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isLatest { Text(build.name).font(.headline).lineLimit(1) }
                    Text("\(build.version.isEmpty ? "—" : build.version) (\(build.build))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if isInstalledInApplications {
                        Image(systemName: "desktopcomputer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Cette release est identique à celle installée dans /Applications.")
                            .accessibilityLabel("Identique à la version installée dans Applications")
                    }
                    if let newerProjectBuild {
                        Label("Build \(newerProjectBuild)", systemImage: "arrow.up.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.18), in: .capsule)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .help("Le projet Xcode est au build \(newerProjectBuild), plus récent que cette release (\(build.build)). Recompilez pour l’exporter.")
                            .accessibilityLabel("Projet plus récent : build \(newerProjectBuild)")
                    }
                    if isRunningPrompt {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.orange)
                            .symbolEffect(.pulse)
                            .help("rClaude exécute un prompt sur ce projet")
                            .accessibilityLabel("rClaude exécute un prompt sur ce projet")
                    }
                }
                Text(details)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// Vrai si l'app de /Applications a le même identifiant, la même version et le même build que cette release macOS.
    private var isInstalledInApplications: Bool {
        IPAStore.isInstalledInApplications(build)
    }

    /// Date · taille · OS minimum · anciens builds · nom du dossier s'il diffère du nom de l'app.
    private var details: String {
        var parts: [String] = []
        if let date = build.folderDate { parts.append(Self.shortDate(date)) }
        parts.append(ByteCountFormatter.string(fromByteCount: build.size, countStyle: .file))
        if let minimum = build.minimumOSVersion { parts.append("\(build.platform == .macOS ? "macOS" : "iOS") \(minimum)+") }
        if olderCount > 0 { parts.append(olderCount == 1 ? "1 ancien" : "\(olderCount) anciens") }
        if build.displayName != build.name { parts.append(build.displayName) }
        return parts.joined(separator: " · ")
    }

    private static let inputFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func shortDate(_ text: String) -> String {
        guard let date = inputFormat.date(from: text) else { return text }
        // « 25 nov 16:25 », avec l'année si ce n'est pas l'année en cours.
        var style = Date.FormatStyle(locale: Locale(identifier: "fr_FR")).day().month(.abbreviated)
        if !Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) { style = style.year() }
        let day = date.formatted(style).replacingOccurrences(of: ".", with: "")
        let time = Calendar.current.dateComponents([.hour, .minute], from: date)
        return day + String(format: " %02d:%02d", time.hour ?? 0, time.minute ?? 0)
    }
}

/// Icône extraite de l'IPA, gardée en mémoire pour la session.
private struct BuildIconView: View {
    let build: IPABuild
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "app.dashed")
                    .resizable().scaledToFit()
                    .padding(6)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
        .task(id: build.id) { await load() }
    }

    private func load() async {
        guard let entry = build.iconEntry else { image = nil; return }
        let key = build.id as NSString
        if let cached = Self.cache.object(forKey: key) { image = cached; return }
        let url = build.fileURL
        let platform = build.platform
        let data = await Task.detached {
            platform == .macOS
                ? IPAMetadataReader.iconPNG(appURL: url, entry: entry)
                : IPAMetadataReader.iconPNG(ipaURL: url, entry: entry)
        }.value
        guard let data, let loaded = NSImage(data: data) else { image = nil; return }
        Self.cache.setObject(loaded, forKey: key)
        image = loaded
    }
}

struct ServeIPASettingsView: View {
    @Bindable var store: IPAStore

    var body: some View {
        Form {
            Section("Dossier des IPA") {
                LabeledContent("Emplacement") {
                    Text(store.folderURL?.path ?? "Aucun dossier choisi")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Choisir…") {
                    store.chooseFolder()
                }
            }
            Section("Dossier des projets") {
                LabeledContent("Emplacement") {
                    Text((store.projectsFolderURL ?? store.folderURL?.deletingLastPathComponent())?.path ?? "Aucun dossier choisi")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Choisir…") {
                    store.chooseProjectsFolder()
                }
                Text("Utilisé pour retrouver le projet Xcode d’une app à recompiler. Par défaut, le dossier parent des IPA.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Mise à jour de ServeIPA") {
                LabeledContent("Version", value: AppBuildInfo.current.summary)
                LabeledContent("Emplacement") {
                    Text(SelfUpdater.runningApp.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Recompiler et relancer ServeIPA…") {
                    Task { await store.updateServeIPA() }
                }
                .disabled(store.folderURL == nil || store.rebuildingBundleID != nil || store.isSelfUpdateBlocked)
                if store.isSelfUpdateBlocked {
                    Text("Prompt rClaude en cours sur le projet ServeIPA : mise à jour indisponible.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let status = store.rebuildStatus, store.rebuildingBundleID == "ServeIPA" {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.caption)
                    }
                }
                Text(SelfUpdater.runsFromBuildFolder
                     ? "ServeIPA tourne depuis Xcode : la version recompilée sera installée dans Applications puis lancée."
                     : "ServeIPA se recompile depuis son projet Xcode (dossier des projets), remplace l’app installée puis se relance. En cas d’échec de l’installation, l’ancienne version est restaurée.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Démarrage") {
                Toggle(
                    "Ouvrir ServeIPA à l’ouverture de session",
                    isOn: Binding(
                        get: { store.launchAtLogin },
                        set: { store.setLaunchAtLogin($0) }
                    )
                )
                Toggle("Démarrer automatiquement le serveur", isOn: $store.startServerAutomatically)
            }
            Section("Nightly build") {
                Toggle("Nightly build", isOn: $store.nightlyBuild)
                Text("Chaque nuit à 1 h, si le serveur tourne, ServeIPA recompile les apps dont le projet est plus récent, supprime les anciennes versions et copie les releases macOS dans /Applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Dock") {
                Toggle("Masquer l’icône du Dock", isOn: $store.hideDockIcon)
                Text("ServeIPA reste accessible depuis l’icône de la barre des menus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Nettoyage") {
                Picker("Builds conservés par app", selection: $store.keepBuildsPerApp) {
                    Text("Tous").tag(0)
                    ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0)").tag($0) }
                }
                Text("Les dossiers d’export plus anciens sont supprimés définitivement du disque à chaque actualisation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("À propos") {
                LabeledContent("ServeIPA", value: AppBuildInfo.current.summary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .padding()
    }
}

#Preview {
    ContentView(store: IPAStore())
}
