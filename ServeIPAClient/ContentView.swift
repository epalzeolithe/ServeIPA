import SwiftUI

#if canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
private typealias PlatformImage = NSImage
#endif

struct ContentView: View {
    @State private var store = ClientStore()
    @State private var searchText = ""
    @State private var showsSettings = false
    #if os(macOS)
    @State private var showsUpdateAll = false
    #endif
    @State private var showsServerMaintenance = false
    @State private var showsAddProject = false
    @State private var logJob: RebuildJob?
    @State private var appToInstall: RemoteApp?
    @State private var appToDelete: RemoteApp?
    @State private var gitRequest: (app: RemoteApp, push: Bool)?
    @State private var commitMessage = ""
    @Environment(\.scenePhase) private var scenePhase

    private var filteredApps: [RemoteApp] {
        guard !searchText.isEmpty else { return store.apps }
        return store.apps.filter {
            [$0.name, $0.displayName, $0.bundleIdentifier, $0.version, $0.build]
                .contains { $0.localizedStandardContains(searchText) }
        }
    }

    #if os(macOS)
    /// Cartes d'état en bas de la fenêtre : compilation sur le Mac serveur et installation locale.
    @ViewBuilder
    private var statusCards: some View {
        VStack(spacing: 8) {
            if !store.visibleJobs.isEmpty {
                // Au-delà de trois jobs, la liste défile.
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.visibleJobs) { jobRow($0) }
                    }
                }
                .frame(height: min(CGFloat(store.visibleJobs.count), 3) * 52)
            }
            if let message = store.downloadMessage {
                let working = store.isInstalling
                StatusCard(
                    state: working ? .working
                        : store.downloadedFile != nil || store.successMessage == message ? .success : .failure,
                    title: store.updateBatch.map { "Mise à jour \($0.index + 1) sur \($0.total)" }
                        ?? (working ? "Installation" : "Installation terminée"),
                    detail: message,
                    badge: nil,
                    dismiss: working ? nil : { store.downloadMessage = nil }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, store.visibleJobs.isEmpty && store.downloadMessage == nil ? 0 : 10)
        .animation(.smooth, value: store.visibleJobs)
        .animation(.smooth, value: store.downloadMessage)
    }

    /// Barre de statut : versions du client et du serveur.
    private var versionBar: some View {
        HStack(spacing: 4) {
            Text("Client \(AppBuildInfo.current.summary)")
            Spacer()
            buildMismatchIcon
            Text(store.serverInfo.map { "Serveur \($0.summary)" } ?? "Serveur non connecté")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    #endif

    /// Petite alerte quand le client et le serveur connecté n'ont pas le même numéro de build.
    @ViewBuilder
    private var buildMismatchIcon: some View {
        if let server = store.serverInfo, server.build != AppBuildInfo.current.build {
            let detail = "Builds différents : client \(AppBuildInfo.current.build), serveur \(server.build)"
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(detail)
                .accessibilityLabel(detail)
        }
    }

    /// iPhone et iPad : l'installation part aussitôt (iOS demande lui-même confirmation). Mac : confirmation,
    /// car l'app ouverte est quittée puis remplacée.
    private func requestInstall(_ app: RemoteApp) {
        #if os(macOS)
        appToInstall = app
        #else
        Task { await store.installCompilingIfNeeded(app) }
        #endif
    }

    /// Vrai pendant l'installation de cette release du client.
    private func isUpdatingClient(_ app: RemoteApp) -> Bool {
        // Compilation préalable à l'installation en cours.
        if store.isAwaitingCompiledInstall(app) { return true }
        #if os(macOS)
        return store.isInstalling
        #else
        return store.pending?.app.bundleIdentifier == app.bundleIdentifier
        #endif
    }

    /// Couleur imposée, pour ne pas dépendre du style que le système donne à un bouton de liste : bleu quand on peut
    /// réessayer, gris avec une roue pendant la tentative.
    private var retryButton: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            HStack(spacing: 6) {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Connexion…")
                } else {
                    Label("Réessayer", systemImage: "arrow.clockwise")
                }
            }
            .foregroundStyle(store.isLoading ? Color.secondary : Color.blue)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(store.isLoading)
    }

    /// Raison affichée sous un bouton de mise à jour grisé.
    private var promptNotice: some View {
        Label("Prompt rClaude en cours sur le projet", systemImage: "sparkles")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private func jobRow(_ job: RebuildJob) -> some View {
        RebuildStatusRow(job: job, macName: store.serverMacName,
                         cancel: { Task { await store.cancel(job) } },
                         showLog: { logJob = job },
                         dismiss: { store.dismiss(job) })
    }

    private var isInstallingOnMac: Bool {
        #if os(macOS)
        store.isInstalling
        #else
        false
        #endif
    }

    #if os(macOS)
    /// Contenu de la confirmation de mise à jour : releases prêtes et projets à compiler.
    private var updateSummary: String {
        var lines: [String] = []
        let ready = store.outdatedInstalledApps
        if !ready.isEmpty {
            lines.append("Releases prêtes : \(ready.map { "\($0.name) (\($0.build))" }.formatted()).")
        }
        let projects = store.compilableInstalledApps
        if !projects.isEmpty {
            lines.append("Projets plus récents, à compiler : \(projects.map { "\($0.name) (\($0.projectBuild ?? 0))" }.formatted()).")
        }
        lines.append("Les apps ouvertes seront quittées avant l’installation puis relancées. rClaude est reporté s’il exécute un prompt.")
        return lines.joined(separator: "\n")
    }
    #endif

    /// Nom de l'app, suivi d'un bouclier vert quand le serveur est accessible.
    private var titleWithShield: some View {
        HStack(spacing: 6) {
            Text("ServeIPA Client")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if store.isConnected { ConnectionShield(store: store) }
        }
    }

    private var groups: [AppGroup] { AppGroup.grouping(filteredApps) }

    @State private var expandedGroups: Set<String> = []

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) || !searchText.isEmpty },
            set: { if $0 { expandedGroups.insert(id) } else { expandedGroups.remove(id) } }
        )
    }

    @State private var flashingAppID: String?
    @State private var flashOn = false

    /// Ouvre l'app en faisant clignoter sa ligne, comme accusé de réception visuel.
    private func openWithFeedback(_ app: RemoteApp) {
        Task { await store.openApp(app) }
        flashingAppID = app.id
        Task {
            for _ in 0..<2 {
                withAnimation(.easeOut(duration: 0.12)) { flashOn = true }
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(.easeIn(duration: 0.18)) { flashOn = false }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if flashingAppID == app.id { flashingAppID = nil }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Petit bouton « × » de fin de ligne (fermer ou annuler).
    private func dismissButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").imageScale(.large)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }

    private func row(for app: RemoteApp, isLatest: Bool, olderCount: Int = 0) -> some View {
        #if os(macOS)
        let record = store.installedApp(app)?.record
        #else
        let record = store.installHistory[app.bundleIdentifier]
        #endif
        return AppRow(app: app,
                      iconURL: isLatest ? store.iconURL(for: app) : nil,
                      isLatest: isLatest,
                      olderCount: olderCount,
                      lastInstall: record,
                      projectBuild: isLatest ? app.projectBuild : nil,
                      isRunningPrompt: isLatest && store.isRunningPrompt(app),
                      isWorking: store.isDownloading(app) || store.committingAppIDs.contains(app.id)
                          || isLatest && (store.isCompiling(app) || store.isAwaitingCompiledInstall(app)),
                      isPresent: isLatest && store.isOpenable(app),
                      downloading: store.downloadingAppID == app.id,
                      downloadDisabled: Platform.isMac ? isInstallingOnMac : store.downloadingAppID != nil,
                      isFlashing: flashingAppID == app.id && flashOn,
                      isUpdateBlocked: store.isUpdateBlocked(app),
                      install: { requestInstall(app) },
                      download: { store.download(app) },
                      open: { openWithFeedback(app) },
                      rebuild: { Task { await store.rebuild(app) } },
                      rebuildDisabled: !store.isConnected || store.isCompilationBlocked(app),
                      commit: { push in
                          commitMessage = "Build \(app.projectBuild ?? Int(app.build) ?? 0)"
                          gitRequest = (app, push)
                      },
                      commitDisabled: !store.isConnected || store.committingAppIDs.contains(app.id),
                      delete: { appToDelete = app })
            #if os(macOS)
            // Double-clic : ouvre l'app installée dans Applications (pas le build du serveur).
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if store.isOpenable(app) { openWithFeedback(app) }
            })
            #endif
            .swipeActions(edge: .trailing) {
                Button("Supprimer", systemImage: "trash", role: .destructive) { appToDelete = app }
            }
    }

    var body: some View {
        NavigationStack {
            List {
                // Serveur accessible : seul le bouclier à côté du titre le signale.
                if !store.isConnected {
                    Section {
                        Label(store.connectionMessage, systemImage: "network.slash")
                            .foregroundStyle(.secondary)
                        retryButton
                        if let helpURL = URL(string: "https://tailscale.com/docs/install/ios") {
                            Link("Configurer Tailscale", destination: helpURL)
                        }
                    }
                }
                if let detail = store.serverUpdateMessage, store.isConnected, !store.isUpdatingServer {
                    Section {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Mise à jour du serveur disponible").font(.subheadline.weight(.semibold))
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                                if store.isSelfUpdateBlocked { promptNotice }
                            }
                            Spacer(minLength: 4)
                            Button("Mettre à jour") { Task { await store.updateServer() } }
                                .buttonStyle(.bordered)
                                .disabled(store.isSelfUpdateBlocked)
                        }
                    }
                }
                if let update = store.clientUpdate, store.isConnected, !isUpdatingClient(update) {
                    Section {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Mise à jour du client disponible").font(.subheadline.weight(.semibold))
                                // Le projet peut être en avance sur la release : c'est lui qui sera compilé.
                                Text("Build \(max(Int(update.build) ?? 0, update.projectBuild ?? 0)) disponible, build \(AppBuildInfo.current.build) en cours.")
                                    .font(.caption).foregroundStyle(.secondary)
                                if store.isSelfUpdateBlocked { promptNotice }
                            }
                            Spacer(minLength: 4)
                            // Sans autre confirmation : iOS demande la sienne, le Mac relance le client.
                            Button("Mettre à jour") { Task { await store.installCompilingIfNeeded(update) } }
                                .buttonStyle(.bordered)
                                .disabled(store.isSelfUpdateBlocked)
                        }
                    }
                }
                if let message = store.linkMessage {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.linkTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            dismissButton("Annuler") { store.cancelLink() }
                        }
                    }
                }
                #if !os(macOS)
                if !store.visibleJobs.isEmpty {
                    Section("Compilations sur \(store.serverMacName)") {
                        ForEach(store.visibleJobs) { jobRow($0) }
                    }
                }
                #endif
                if let pending = store.pending {
                    Section {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(pending.app.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if let transfer = store.transfer, transfer.total > 0 {
                                        Text("\(Self.size(transfer.sent)) / \(Self.size(transfer.total))")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                if let transfer = store.transfer, transfer.total > 0 {
                                    ProgressView(value: Double(transfer.sent), total: Double(transfer.total))
                                }
                                Text((store.installMessage ?? "Suivi de l’installation…")
                                     + (pending.detectionSupported && pending.wasDetectable ? " App déjà présente : fin non détectable." : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            dismissButton("Fermer le suivi") { store.clearPending() }
                        }
                    }
                }
                #if !os(macOS)
                if let message = store.downloadMessage {
                    Section {
                        HStack(spacing: 10) {
                            if store.downloadingAppID != nil { ProgressView() }
                            Text(message).font(.subheadline).lineLimit(2)
                            Spacer(minLength: 4)
                            if let file = store.downloadedFile {
                                ShareLink(item: file) {
                                    Label("Partager ou enregistrer dans Fichiers", systemImage: "square.and.arrow.up")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                            }
                            if store.downloadingAppID != nil {
                                dismissButton("Annuler le téléchargement") { store.cancelDownload() }
                            } else {
                                dismissButton("Fermer") { store.downloadMessage = nil }
                            }
                        }
                    }
                }
                #endif
                Section {
                    ForEach(groups) { group in
                        if group.older.isEmpty {
                            row(for: group.latest, isLatest: true)
                        } else {
                            DisclosureGroup(isExpanded: expansionBinding(for: group.id)) {
                                ForEach(group.older) { app in row(for: app, isLatest: false) }
                            } label: {
                                row(for: group.latest, isLatest: true, olderCount: group.older.count)
                            }
                        }
                    }
                    if groups.isEmpty && store.isConnected {
                        ContentUnavailableView(searchText.isEmpty ? (Platform.isMac ? "Aucune app macOS" : "Aucun IPA disponible") : "Aucun résultat",
                                               systemImage: "shippingbox",
                                               description: Text(Platform.isMac
                                                   ? "Aucune app macOS n’est exportée sur le serveur. Recompilez-en une depuis ServeIPA, ou mettez-le à jour."
                                                   : "Ajoutez des IPA dans les sous-dossiers du dossier choisi sur le Mac."))
                    }
                } header: {
                    Text("Applications · \(groups.count)")
                } footer: {
                    #if !os(macOS)
                    // Comme sur Mac : client à gauche, serveur à droite, chacun sur une ligne
                    // (le texte rétrécit sur les écrans étroits).
                    HStack(spacing: 8) {
                        Text("Client \(AppBuildInfo.current.summary)")
                        Spacer(minLength: 0)
                        buildMismatchIcon
                        Text(store.serverInfo.map { "Serveur \($0.summary)" } ?? "Serveur non connecté")
                    }
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    #endif
                }
            }
            .navigationTitle("ServeIPA Client")
            #if os(iOS)
            // Titre en ligne, remplacé par le nom suivi du bouclier.
            .navigationBarTitleDisplayMode(.inline)
            #else
            .toolbar(removing: .title)
            #endif
            .searchable(text: $searchText, prompt: "App, version ou identifiant")
            .refreshable { await store.refresh() }
            #if os(macOS)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    statusCards
                    Divider()
                    versionBar
                }
                .background(.bar)
            }
            #endif
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .navigation) { titleWithShield }
                    // Sans le fond en capsule que la barre d'outils dessine autour d'un élément.
                    .sharedBackgroundVisibility(.hidden)
                #else
                ToolbarItem(placement: .principal) { titleWithShield }
                #endif
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button("Mettre à jour les apps installées", systemImage: "arrow.down.app") {
                        showsUpdateAll = true
                    }
                    .help("Télécharger et installer toutes les versions plus récentes du serveur")
                    .disabled((store.outdatedInstalledApps.isEmpty && store.compilableInstalledApps.isEmpty) || store.isInstalling)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Rafraîchir", systemImage: "arrow.clockwise") {
                        Task { await store.refresh() }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isLoading)
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Button("Ajouter un projet depuis le Mac", systemImage: "plus.app") {
                        showsAddProject = true
                    }
                    .help("Scanner les projets Xcode du Mac et en compiler un nouveau")
                    .disabled(!store.isConnected)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Baguette magique sur le Mac", systemImage: "wand.and.stars") {
                        showsServerMaintenance = true
                    }
                    .help("Recompiler sur le Mac les apps dont le projet est plus récent, nettoyer les anciennes versions et copier les releases dans /Applications")
                    .disabled(!store.isConnected)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Réglages", systemImage: "gear") { showsSettings = true }
                }
            }
            .sheet(isPresented: $showsSettings) { ClientSettings(store: store) }
            .sheet(isPresented: $showsAddProject) { AddProjectSheet(store: store) }
            .sheet(item: $logJob) { BuildLogSheet(store: store, job: $0) }
            .confirmationDialog("Lancer la baguette magique sur le Mac ?", isPresented: $showsServerMaintenance,
                                titleVisibility: .visible) {
                Button("Recompiler puis nettoyer") {
                    Task { await store.runServerMaintenance() }
                }
            } message: {
                Text("Le Mac recompile les apps dont le projet est plus récent que leur release, ne garde que le build le plus récent de chaque app (les autres sont supprimés définitivement) et copie les releases macOS dans son dossier /Applications.")
            }
            #if os(macOS)
            .confirmationDialog("Mettre à jour les apps installées ?", isPresented: $showsUpdateAll,
                                titleVisibility: .visible) {
                if !store.compilableInstalledApps.isEmpty {
                    Button("Compiler puis mettre à jour") {
                        Task { await store.compileThenUpdate() }
                    }
                }
                if !store.outdatedInstalledApps.isEmpty {
                    Button("Installer \(store.outdatedInstalledApps.count) release(s) disponible(s)") {
                        Task { await store.updateInstalledApps() }
                    }
                }
            } message: {
                Text(updateSummary)
            }
            // Seuls les boutons répondent : la fermeture de la feuille ne doit pas devancer le choix.
            .confirmationDialog("Forcer l’app à quitter ?", isPresented: Binding(
                get: { store.quitRequest != nil }, set: { _ in }
            ), titleVisibility: .visible, presenting: store.quitRequest) { request in
                Button("Forcer \(request.name) à quitter et installer", role: .destructive) {
                    store.answerQuitRequest(request.id, force: true)
                }
                Button("Plus tard", role: .cancel) {
                    store.answerQuitRequest(request.id, force: false)
                }
            } message: { request in
                Text("\(request.name) n’a pas quitté. La forcer fait perdre le travail non enregistré. Avec « Plus tard », rien n’est modifié.")
            }
            #endif
            .confirmationDialog("Installer cette app ?", isPresented: Binding(
                get: { appToInstall != nil }, set: { if !$0 { appToInstall = nil } }
            ), titleVisibility: .visible, presenting: appToInstall) { app in
                Button("Installer \(app.name)") {
                    appToInstall = nil
                    Task { await store.installCompilingIfNeeded(app) }
                }
            } message: { app in
                let build = store.compilesBeforeInstalling(app)
                    ? "Le projet (build \(app.projectBuild ?? 0)) est plus récent que la release (build \(app.build)) : il sera d’abord compilé sur le Mac serveur."
                    : "Build \(app.build)."
                Text("\(build) L’app sera installée dans Applications et remplacera la version présente. Si elle est ouverte, elle sera quittée avant l’installation puis relancée.")
            }
            .alert(gitRequest?.push == true ? "Stage, commit et push" : "Stage et commit", isPresented: Binding(
                get: { gitRequest != nil }, set: { if !$0 { gitRequest = nil } }
            ), presenting: gitRequest) { request in
                TextField("Message du commit", text: $commitMessage)
                Button(request.push ? "Commit et push" : "Commit") {
                    let message = commitMessage
                    gitRequest = nil
                    Task { await store.commit(request.app, message: message, push: request.push) }
                }
                Button("Annuler", role: .cancel) { gitRequest = nil }
            } message: { request in
                Text("Tous les fichiers modifiés ou nouveaux du projet « \(request.app.name) » seront ajoutés au commit sur le Mac serveur\(request.push ? ", puis poussés vers le dépôt distant" : "").")
            }
            .confirmationDialog("Supprimer cet IPA du serveur ?", isPresented: Binding(
                get: { appToDelete != nil }, set: { if !$0 { appToDelete = nil } }
            ), titleVisibility: .visible, presenting: appToDelete) { app in
                Button("Supprimer \(app.name) (\(app.build))", role: .destructive) {
                    appToDelete = nil
                    Task { await store.delete(app) }
                }
            } message: { app in
                Text("Le dossier « \(app.displayName) » et son contenu seront supprimés du Mac. Cette action est définitive.")
            }
            .alert("ServeIPA", isPresented: Binding(
                get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            #if os(macOS)
            // Le suivi continue quand l'app passe derrière une autre, pour notifier la fin des compilations.
            .task { await store.monitor() }
            #else
            .task(id: scenePhase) {
                if scenePhase == .active { await store.monitor() }
            }
            .onChange(of: scenePhase) {
                if scenePhase == .background, store.needsBackgroundCheck { JobRefresh.schedule() }
            }
            #endif
            .onOpenURL { store.handle($0) }
        }
    }
}

private struct AppRow: View {
    let app: RemoteApp
    /// Icône du build ; nil pour les builds précédents d'un groupe (affichés sans icône).
    let iconURL: URL?
    /// Build le plus récent de son app (ligne principale du groupe).
    let isLatest: Bool
    let olderCount: Int
    /// Dernière installation de cette app lancée depuis ce client.
    let lastInstall: InstallRecord?
    /// Build du projet Xcode, s'il est plus récent que celui du serveur (le serveur ne le publie que dans ce cas).
    var projectBuild: Int?
    /// rClaude exécute un prompt sur le projet de cette app.
    var isRunningPrompt = false
    /// Compilation ou téléchargement en cours pour cette ligne.
    let isWorking: Bool
    /// Une app ouvrable via le schéma d'URL de ce build est présente sur l'appareil (version inconnue).
    let isPresent: Bool
    let downloading: Bool
    let downloadDisabled: Bool
    /// Clignotement de confirmation après une demande d'ouverture.
    let isFlashing: Bool
    /// Client ou serveur pendant un prompt sur leur projet : installation impossible.
    let isUpdateBlocked: Bool
    let install: () -> Void
    let download: () -> Void
    let open: () -> Void
    let rebuild: () -> Void
    let rebuildDisabled: Bool
    /// Stage et commit du projet, avec push si vrai.
    let commit: (Bool) -> Void
    let commitDisabled: Bool
    let delete: () -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Compiler et Lancer encadrent le bouton d'installation sur Mac, et sur iPad quand la largeur le permet.
    private var showsAllButtons: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
        #else
        true
        #endif
    }

    private var showsLaunch: Bool { isLatest && (Platform.isMac || isPresent) }

    /// La version installée est celle du serveur : coche verte.
    private var isInstalledRelease: Bool { lastInstall?.matches(app) == true }
    /// Le serveur a une version plus récente que celle installée.
    private var isNewer: Bool { isLatest && lastInstall?.isOlder(than: app) == true }

    /// Badge « Nouveau » : serveur plus récent que la version installée, ou projet à compiler plus récent que le
    /// serveur ou que la version installée.
    private var showsNewBadge: Bool {
        guard isLatest else { return false }
        if isNewer { return true }
        guard let projectBuild else { return false }
        if let server = Int(app.build), projectBuild > server { return true }
        guard let installed = lastInstall.flatMap({ Int($0.build) }) else { return false }
        return projectBuild > installed
    }

    var body: some View {
        HStack(spacing: 10) {
            if isLatest {
                AppIconView(url: iconURL)
            } else {
                Color.clear.frame(width: 36, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                // Une seule ligne si tout tient (Mac, iPhone en paysage) ; sinon les badges passent sur leur
                // propre ligne ; en dernier recours (iPhone en portrait), le nom occupe seul toute la largeur
                // (sur deux lignes au besoin) et la version passe dessous avec les badges.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        nameItem
                        versionItems
                        badgeItems
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) { nameItem; versionItems }
                        if hasBadges {
                            HStack(spacing: 6) { badgeItems }
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if isLatest {
                            Text(app.name)
                                .font(.headline)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) { versionItems; badgeItems }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) { versionItems }
                                if hasBadges {
                                    HStack(spacing: 6) { badgeItems }
                                }
                            }
                        }
                    }
                }
                detailsText
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(Platform.isMac ? 1 : 2)
            }
            Spacer(minLength: 0)
            if showsAllButtons {
                Button("Compiler sur le Mac serveur", systemImage: "hammer.fill", action: rebuild)
                    .labelStyle(.iconOnly)
                    .buttonStyle(GlassActionStyle.compile)
                    .disabled(rebuildDisabled)
                    .help(rebuildDisabled && (isRunningPrompt || isUpdateBlocked)
                          ? "Prompt rClaude en cours : compilation indisponible" : "Compiler sur le Mac serveur")
            }
            Button(Platform.isMac ? "Installer dans Applications" : "Installer",
                   systemImage: "arrow.down.to.line", action: install)
                .labelStyle(.iconOnly)
                .buttonStyle(GlassActionStyle.install)
                .disabled((Platform.isMac && downloadDisabled) || isUpdateBlocked)
                .help(isUpdateBlocked ? ClientStore.selfUpdateBlockedMessage
                      : Platform.isMac ? "Télécharger et installer dans Applications" : "Installer")
            if showsAllButtons {
                // Mac : grisé si l'app n'est pas installée. iPad : affiché seulement si son schéma de lancement est
                // détecté (déclaré dans ce client et pris en charge par une app). Absent des builds précédents.
                Button("Lancer l’app", systemImage: "play.fill", action: open)
                    .labelStyle(.iconOnly)
                    .buttonStyle(GlassActionStyle.launch)
                    .disabled(!isPresent)
                    // Masqué sans libérer sa place, pour garder les boutons alignés d'une ligne à l'autre. Une simple
                    // opacité nulle ne suffit pas toujours à effacer un effet de verre.
                    .modifier(HiddenKeepingSpace(isHidden: !showsLaunch))
                    .help(!Platform.isMac ? "Lancer l’app"
                          : isPresent ? "Lancer l’app installée dans Applications" : "App non installée dans Applications")
            }
            Menu {
                // En tête du menu : le nom de l’app (plus parlant que son identifiant de bundle).
                Section(app.name) {
                    if !Platform.isMac {
                        Button(downloading ? "Téléchargement…" : "Télécharger le fichier IPA",
                               systemImage: "arrow.down.doc", action: download)
                            .disabled(downloadDisabled)
                    }
                    // Sur iOS, l'ouverture par schéma d'URL n'est pas proposée ; sur Mac, ouvre l'app installée.
                    if Platform.isMac && isPresent {
                        Button("Ouvrir l’app", systemImage: "arrow.up.forward.app", action: open)
                    }
                }
                // Dans le menu seulement quand le bouton Compiler n’est pas déjà affiché sur la ligne (iPhone).
                if !showsAllButtons {
                    Button("Recompiler sur le Mac", systemImage: "hammer", action: rebuild)
                        .disabled(rebuildDisabled)
                }
                // Le projet est commun à tous les builds : proposé sur la ligne principale seulement.
                if isLatest {
                    Section("Git") {
                        Button("Stage et commit…", systemImage: "checkmark.circle") { commit(false) }
                        Button("Stage, commit et push…", systemImage: "arrow.up.circle") { commit(true) }
                    }
                    .disabled(commitDisabled)
                }
                Button("Supprimer du serveur", systemImage: "trash", role: .destructive, action: delete)
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isFlashing ? 0.35 : 0))
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
        )
    }

    private var hasBadges: Bool { showsNewBadge }

    /// Version installée, connue pour la ligne principale seulement (sur iOS, d'après les installations faites d'ici).
    private var installed: InstallRecord? { isLatest ? lastInstall : nil }

    /// Nom de l'app, sur la ligne principale du groupe seulement.
    @ViewBuilder
    private var nameItem: some View {
        if isLatest { Text(app.name).font(.headline).lineLimit(1) }
    }

    /// Petite icône animée tant que rClaude travaille sur ce projet.
    @ViewBuilder
    private var promptIndicator: some View {
        if isRunningPrompt {
            Image(systemName: "sparkles")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
                .help("rClaude exécute un prompt sur ce projet")
                .accessibilityLabel("rClaude exécute un prompt sur ce projet")
        }
    }

    /// Les numéros côte à côte, dans l'ordre : installé, disponible sur le serveur, projet à compiler.
    /// Ils s'empilent quand la largeur manque.
    /// La roue d'activité puis l'indicateur de prompt les suivent sur la même ligne, quelle que soit la largeur.
    private var versionItems: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) { versionNumbers }
                VStack(alignment: .leading, spacing: 2) { versionNumbers }
            }
            if isWorking {
                ActivityBadge()
                    .help("Compilation ou téléchargement en cours")
                    .accessibilityLabel("Compilation ou téléchargement en cours")
            }
            promptIndicator
        }
        .layoutPriority(1)
    }

    @ViewBuilder
    private var versionNumbers: some View {
        if let installed {
            number(installed.build,
                   symbol: Platform.isMac ? "desktopcomputer" : "iphone", color: .secondary,
                   label: Platform.isMac ? "Version installée" : "Dernière version installée via ServeIPA")
        }
        HStack(spacing: 4) {
            // Les builds précédents d'un groupe n'ont que leur numéro, sans icône.
            number(app.build, symbol: isLatest ? "server.rack" : nil,
                   color: isNewer ? .accentColor : .secondary, label: "Version disponible sur le serveur")
            if isLatest && isInstalledRelease {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Version installée à jour")
            }
            // iOS : app détectée sur l'appareil sans qu'on connaisse sa version.
            if isPresent && installed == nil && !Platform.isMac {
                Image(systemName: "iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("App présente sur cet appareil")
            }
        }
        if let projectBuild {
            number("\(projectBuild)", symbol: "hammer", color: .orange,
                   label: "Build du projet Xcode, à compiler sur le Mac serveur")
        }
    }

    private func number(_ text: String, symbol: String?, color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.caption2)
            }
            Text(text).font(.subheadline.monospacedDigit())
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
        .help("\(label) : \(text)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) : \(text)")
    }

    @ViewBuilder
    private var badgeItems: some View {
        if showsNewBadge {
            Text("Nouveau")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.tint, in: .capsule)
                .foregroundStyle(.white)
                .fixedSize()
                .accessibilityLabel("Version plus récente disponible")
        }
    }

    /// En tête de ligne : l'icône du serveur et le numéro de build qui y est disponible, avant sa date. Puis la taille,
    /// le dernier commit et le dernier push du projet, et le nom du dossier s’il diffère du nom de l’app.
    private var detailsText: Text {
        var head: [String] = []
        if let date = app.date { head.append(Self.shortDate(date)) }
        head.append(ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file))
        var text = Text("\(Image(systemName: "server.rack")) (\(app.build)) \(head.joined(separator: " · "))")
        if isLatest {
            if let commit = app.lastCommit {
                text = Text("\(text) · \(gitEvent("commit", app.lastCommitBuild, commit))")
            }
            if let push = app.lastPush {
                text = Text("\(text) · \(gitEvent("push", app.lastPushBuild, push))")
            }
        }
        var tail: [String] = []
        if olderCount > 0 { tail.append(olderCount == 1 ? "1 ancien" : "\(olderCount) anciens") }
        // Nom du dossier d'export (souvent le scheme Xcode) : utile sur Mac seulement.
        if app.isMac, app.displayName != app.name { tail.append(app.displayName) }
        return tail.isEmpty ? text : Text("\(text) · \(tail.joined(separator: " · "))")
    }

    /// Numéro le plus avancé connu pour cette app : release, projet, commit ou push.
    private var mostRecentBuild: Int {
        [Int(app.build), app.projectBuild, app.lastCommitBuild, app.lastPushBuild].compactMap { $0 }.max() ?? 0
    }

    /// « commit (53) 22 nov 14:48 » : le numéro de build précède la date, quand il est connu. Une petite horloge
    /// orange le suit s'il est en retard sur le plus récent.
    private func gitEvent(_ name: String, _ build: Int?, _ seconds: Double) -> Text {
        let date = Self.shortDate(Date(timeIntervalSince1970: seconds))
        guard let build else { return Text("\(name) \(date)") }
        guard build < mostRecentBuild else { return Text("\(name) (\(String(build))) \(date)") }
        let mark = Text(Image(systemName: "clock.badge.exclamationmark")).foregroundStyle(.orange)
            .accessibilityLabel("En retard sur le build \(mostRecentBuild)")
        return Text("\(name) (\(String(build))) \(mark) \(date)")
    }

    private static let inputFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func shortDate(_ text: String) -> String {
        guard let date = inputFormat.date(from: text) else { return text }
        return shortDate(date)
    }

    private static func shortDate(_ date: Date) -> String {
        AppDate.short(date)
    }
}

/// Boutons d'action d'une ligne en « Liquid Glass » : capsules de verre teinté de même taille, symbole blanc.
/// Verre neutre si désactivé. Seule la teinte distingue les actions.
private struct GlassActionStyle: ButtonStyle {
    let tint: Color

    static let compile = Self(tint: .orange)
    static let install = Self(tint: .blue)
    static let launch = Self(tint: .green)

    func makeBody(configuration: Configuration) -> some View {
        Face(tint: tint, configuration: configuration)
    }

    private struct Face: View {
        let tint: Color
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: Platform.isMac ? 12 : 15, weight: .semibold))
                .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                .frame(width: Platform.isMac ? 34 : 42, height: Platform.isMac ? 22 : 30)
                .contentShape(.capsule)
                .modifier(GlassCapsule(tint: isEnabled ? tint.opacity(0.8) : nil))
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        }
    }
}

/// Fond de verre en capsule, teinté ou neutre. Avant iOS 26, un matériau translucide le remplace.
private struct GlassCapsule: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(tint.map { .regular.tint($0).interactive() } ?? .regular, in: .capsule)
        } else {
            content.background {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(tint ?? .clear)
                Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1)
            }
        }
    }
}

/// Petite roue d'activité alignée sur une ligne de texte. Seule, elle n'a pas de ligne de base : dans une rangée
/// alignée sur le texte, elle se pose dessus et paraît trop haute. Elle est donc centrée sur un texte invisible.
private struct ActivityBadge: View {
    var body: some View {
        Text(verbatim: "0")
            .font(.subheadline)
            .hidden()
            .frame(width: 16)
            .overlay { ProgressView().controlSize(.mini) }
    }
}

/// Efface une vue en gardant sa place.
private struct HiddenKeepingSpace: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        if isHidden { content.hidden() } else { content }
    }
}

/// Bouclier vert : le toucher affiche les informations de connexion au serveur.
private struct ConnectionShield: View {
    let store: ClientStore
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails = true } label: {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(store.connectionMessage)
        .help(store.connectionMessage)
        .popover(isPresented: $showsDetails) {
            details
                .padding()
                .frame(minWidth: 300, idealWidth: 340)
                // iPhone : une petite bulle sous le bouclier plutôt qu'une feuille.
                .presentationCompactAdaptation(.popover)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(store.connectionMessage, systemImage: "checkmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Divider()
            row("Adresse", store.address)
            if let host = store.serverHostName { row("Mac", host) }
            row("Serveur", store.serverInfo?.summary ?? "Version non communiquée")
            row("Apps", "\(AppGroup.grouping(store.apps).count)")
            if let date = store.lastContact {
                row("Actualisé", date.formatted(date: .omitted, time: .standard))
            }
            Button("Actualiser", systemImage: "arrow.clockwise") {
                Task { await store.refresh() }
            }
            .disabled(store.isLoading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Compilation sur le Mac : en file, en cours (annulable), réussie, annulée ou en échec.
private struct RebuildStatusRow: View {
    let job: RebuildJob
    let macName: String
    let cancel: () -> Void
    let showLog: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            switch job.state {
            case "succeeded":
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            case "failed":
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.title3)
            case "cancelled":
                Image(systemName: "slash.circle").foregroundStyle(.secondary).font(.title3)
            case "queued":
                Image(systemName: "clock").foregroundStyle(.secondary).font(.title3)
            default:
                ProgressView()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title(on: macName))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(job.detail)
                    .font(.caption)
                    .foregroundStyle(job.state == "failed" ? Color.red : Color.secondary)
                    .lineLimit(Platform.isMac ? 2 : 4)
            }
            Spacer(minLength: 0)
            // Une demande en file n'a pas encore de journal.
            if job.state != "queued" {
                button("Voir le journal", systemImage: "doc.text", action: showLog)
            }
            if job.isFinished {
                button("Fermer", systemImage: "xmark.circle.fill", action: dismiss)
            } else {
                button("Annuler la compilation", systemImage: "stop.circle", action: cancel)
            }
        }
        .animation(.smooth, value: job)
    }

    private func button(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(label)
    }
}

/// Fin du journal de compilation conservé sur le Mac, actualisée tant que le job tourne.
private struct BuildLogSheet: View {
    let store: ClientStore
    let job: RebuildJob
    @State private var text = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let error, text.isEmpty {
                    ContentUnavailableView("Journal indisponible", systemImage: "doc.questionmark",
                                           description: Text(error))
                } else if text.isEmpty {
                    ProgressView()
                } else {
                    ScrollView {
                        // Seules les dernières lignes sont affichées ; le partage transmet tout le texte reçu.
                        Text(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(400)
                            .joined(separator: "\n"))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .defaultScrollAnchor(.bottom)
                }
            }
            .navigationTitle("Journal · \(job.app)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: text).disabled(text.isEmpty)
                }
            }
            .task {
                repeat {
                    await load()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                } while store.job(job.id)?.isFinished == false
                await load()
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 440)
        #endif
    }

    private func load() async {
        do {
            text = try await store.buildLog(job.id)
            error = nil
        } catch ClientError.http(404) {
            error = "Aucun journal pour ce travail sur le Mac."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Icône d'app chargée depuis le serveur, gardée en mémoire pour la session.
private struct AppIconView: View {
    let url: URL?
    @State private var image: PlatformImage?

    private static let cache = NSCache<NSURL, PlatformImage>()

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
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
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              response.url?.scheme == "https",
              let loaded = PlatformImage(data: data) else { return }
        Self.cache.setObject(loaded, forKey: url as NSURL)
        image = loaded
    }
}

/// Interrupteur d'une famille de notifications.
private struct NotificationToggle: View {
    let kind: NotificationKind
    @AppStorage private var isOn: Bool

    init(kind: NotificationKind) {
        self.kind = kind
        _isOn = AppStorage(wrappedValue: kind.enabledByDefault, kind.key)
    }

    var body: some View {
        Toggle(kind.title, isOn: $isOn)
    }
}

private struct ClientSettings: View {
    @Bindable var store: ClientStore
    @State private var address = ""
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Serveur") {
                    TextField("https://serveur.ts.net", text: $address)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .accessibilityLabel("Adresse HTTPS du serveur")
                    Text("Connectez cet appareil au même réseau Tailscale que le Mac. Le diagnostic vérifie l’accès réel au serveur.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Installation") {
                    Toggle("Ouvrir automatiquement si détectable", isOn: $store.autoOpen)
                    Text("Fonctionne au premier plan pour une nouvelle app dont le schéma d’URL est déclaré dans ce client. Une app déjà présente ou sans schéma détectable doit être ouverte manuellement. La version installée n’est pas vérifiable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Notifications") {
                    ForEach(NotificationKind.available, id: \.self) { kind in
                        NotificationToggle(kind: kind)
                    }
                    Text(Platform.isMac
                         ? "Envoyées tant que la fenêtre de ServeIPAClient est ouverte. Autorisez-les aussi dans les Réglages Système."
                         : "En arrière-plan, iOS choisit le moment des vérifications : une notification peut arriver tard. Autorisez-les aussi dans l’app Réglages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("À propos") {
                    LabeledContent("Client", value: AppBuildInfo.current.summary)
                    LabeledContent("Serveur", value: store.serverInfo?.summary ?? "Non communiqué")
                    if let detail = store.serverUpdateMessage {
                        Text("Mise à jour disponible. \(detail)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Mettre à jour le serveur", systemImage: "arrow.triangle.2.circlepath") {
                        Task {
                            await store.updateServer()
                            // Le suivi (ou l'erreur) s'affiche dans la fenêtre principale.
                            dismiss()
                        }
                    }
                    .disabled(!store.isConnected || store.isUpdatingServer || store.isSelfUpdateBlocked)
                    if store.isSelfUpdateBlocked {
                        Text(ClientStore.selfUpdateBlockedMessage).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Réglages")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        isSaving = true
                        Task {
                            if await store.saveAddress(address) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .onAppear { address = store.address }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 620)
        #endif
    }
}

/// Feuille « Ajouter un projet » : le Mac scanne son dossier de projets Xcode, on choisit l'app à compiler.
private struct AddProjectSheet: View {
    @Bindable var store: ClientStore
    @Environment(\.dismiss) private var dismiss
    @State private var starting: Set<String> = []
    @State private var addError: String?

    private var addable: [RemoteProject] {
        store.remoteProjects.filter { $0.problem == nil && $0.platforms.contains { !$0.served } }
    }
    private var served: [RemoteProject] {
        store.remoteProjects.filter { $0.problem == nil && !$0.platforms.isEmpty && !$0.platforms.contains { !$0.served } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isScanningRemote {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Le Mac scanne ses projets Xcode…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = store.remoteScanError {
                    ContentUnavailableView("Scan impossible", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if addable.isEmpty && served.isEmpty {
                    ContentUnavailableView("Aucun projet", systemImage: "magnifyingglass",
                                           description: Text("Le Mac n’a trouvé aucun projet Xcode compilable."))
                } else {
                    List {
                        if let addError {
                            Label(addError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        }
                        if !addable.isEmpty {
                            Section("À ajouter") { ForEach(addable) { row($0) } }
                        }
                        if !served.isEmpty {
                            Section("Déjà servies") { ForEach(served) { row($0) } }
                        }
                    }
                }
            }
            .navigationTitle("Ajouter un projet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Scanner", systemImage: "arrow.clockwise") {
                        Task { await store.scanRemoteProjects() }
                    }
                    .disabled(store.isScanningRemote)
                }
            }
            .task { if store.remoteProjects.isEmpty { await store.scanRemoteProjects() } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }

    private func row(_ project: RemoteProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.name).font(.headline)
            Text([project.bundleIdentifier, project.folder].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack {
                ForEach(project.platforms, id: \.name) { platform in
                    if platform.served {
                        Label(platform.name, systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
                    } else {
                        control(project, platform.name)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Bouton d'ajout, ou état de la demande déjà faite.
    @ViewBuilder
    private func control(_ project: RemoteProject, _ platform: String) -> some View {
        let key = store.projectKey(project, platform: platform)
        let job = store.requestedProjects[key].flatMap { store.job($0) }
        switch job?.state {
        case "queued":
            Label("\(platform) en file", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        case "running":
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(platform) en compilation").font(.caption)
            }
        case "succeeded":
            Label("\(platform) ajoutée", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        default:
            Button(job?.state == "failed" ? "Réessayer \(platform)" : "Ajouter \(platform)", systemImage: "plus") {
                start(project, platform)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(starting.contains(key) || store.isCompilationBlocked(project))
            .help(store.isCompilationBlocked(project) ? ClientStore.compilationBlockedMessage(project.name) : "")
        }
    }

    private func start(_ project: RemoteProject, _ platform: String) {
        let key = store.projectKey(project, platform: platform)
        starting.insert(key)
        Task {
            addError = await store.addRemoteProject(project, platform: platform)
            starting.remove(key)
        }
    }
}

private extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

#if os(macOS)
/// Carte d'état affichée en bas de la fenêtre : étape en cours, succès ou échec.
private struct StatusCard: View {
    enum State { case working, success, failure }

    let state: State
    let title: String
    let detail: String
    let badge: String?
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            switch state {
            case .working:
                ProgressView().controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            case .failure:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.title3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(state == .failure ? Color.red : Color.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: .capsule)
                    .foregroundStyle(.tint)
            }
            if let dismiss {
                Button("Fermer", systemImage: "xmark.circle.fill", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .animation(.smooth, value: detail)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
#endif
