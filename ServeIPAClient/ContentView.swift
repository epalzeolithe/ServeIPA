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
    @State private var appToInstall: RemoteApp?
    @State private var appToDelete: RemoteApp?
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
            if let job = store.visibleRebuild {
                StatusCard(
                    state: job.state == "failed" ? .failure : job.state == "succeeded" ? .success : .working,
                    title: job.state == "running" ? "Recompilation de \(job.app)" : job.app,
                    detail: job.state == "succeeded" ? "Terminé — le nouveau build est dans la liste."
                        : job.state == "failed" ? (job.error ?? "La compilation a échoué.") : job.step,
                    badge: job.platform,
                    dismiss: job.state == "running" ? nil : { store.dismissRebuild() }
                )
            }
            if let message = store.downloadMessage {
                let working = store.downloadingAppID != nil || store.updateBatch != nil
                StatusCard(
                    state: working ? .working : store.downloadedFile != nil ? .success : .failure,
                    title: store.updateBatch.map { "Mise à jour \($0.index + 1) sur \($0.total)" }
                        ?? (working ? "Installation" : "Installation terminée"),
                    detail: message,
                    badge: nil,
                    dismiss: working ? nil : { store.downloadMessage = nil }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, store.visibleRebuild == nil && store.downloadMessage == nil ? 0 : 10)
        .animation(.smooth, value: store.visibleRebuild)
        .animation(.smooth, value: store.downloadMessage)
    }
    #endif

    private var groups: [AppGroup] { AppGroup.grouping(filteredApps) }

    @State private var expandedGroups: Set<String> = []

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) || !searchText.isEmpty },
            set: { if $0 { expandedGroups.insert(id) } else { expandedGroups.remove(id) } }
        )
    }

    /// Build du projet à signaler : plus récent que la release du serveur et que la dernière version installée
    /// (lue sur le Mac ; sur iOS, d'après l'historique des installations faites depuis ce client).
    private func newerProjectBuild(for app: RemoteApp, installed: InstallRecord?) -> Int? {
        guard let projectBuild = app.projectBuild else { return nil }
        if let installed, let installedBuild = Int(installed.build), installedBuild >= projectBuild { return nil }
        return projectBuild
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
                      projectBuild: isLatest ? newerProjectBuild(for: app, installed: record) : nil,
                      isPresent: isLatest && store.isOpenable(app),
                      downloading: store.downloadingAppID == app.id,
                      downloadDisabled: store.downloadingAppID != nil,
                      install: { appToInstall = app },
                      download: { store.download(app) },
                      open: { Task { await store.openApp(app) } },
                      rebuild: { Task { await store.rebuild(app) } },
                      rebuildDisabled: store.rebuildJob?.state == "running",
                      delete: { appToDelete = app })
            #if os(macOS)
            // Double-clic : ouvre l'app installée dans Applications (pas le build du serveur).
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if store.isOpenable(app) { Task { await store.openApp(app) } }
            })
            #endif
            .swipeActions(edge: .trailing) {
                Button("Supprimer", systemImage: "trash", role: .destructive) { appToDelete = app }
            }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(store.connectionMessage, systemImage: store.isConnected ? "checkmark.shield" : "network.slash")
                        .foregroundStyle(store.isConnected ? Color.green : Color.secondary)
                    if !store.isConnected {
                        Button("Réessayer", systemImage: "arrow.clockwise") {
                            Task { await store.refresh() }
                        }
                        .disabled(store.isLoading)
                        if let helpURL = URL(string: "https://tailscale.com/docs/install/ios") {
                            Link("Configurer Tailscale", destination: helpURL)
                        }
                    }
                }
                #if !os(macOS)
                if let job = store.visibleRebuild {
                    Section("Compilation sur le Mac") {
                        RebuildStatusRow(job: job, dismiss: { store.dismissRebuild() })
                    }
                }
                #endif
                if let pending = store.pending {
                    Section("Installation de \(pending.app.name)") {
                        Text(store.installMessage ?? "Suivi de l’installation…")
                        if let transfer = store.transfer, transfer.total > 0 {
                            ProgressView(value: Double(transfer.sent), total: Double(transfer.total))
                            Text("\(ByteCountFormatter.string(fromByteCount: transfer.sent, countStyle: .file)) sur \(ByteCountFormatter.string(fromByteCount: transfer.total, countStyle: .file))")
                                .font(.caption)
                        }
                        if pending.app.launchURL != nil {
                            Button("Ouvrir l’app", systemImage: "arrow.up.forward.app") {
                                Task { await store.openApp(pending.app) }
                            }
                        }
                        if !pending.detectionSupported {
                            Text("Ouverture automatique indisponible pour cette app. Utilisez « Ouvrir l’app » après son installation.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if pending.wasDetectable {
                            Text("L’app était déjà présente : iOS ne permet pas de détecter la fin de sa mise à jour.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Fermer le suivi") { store.clearPending() }
                    }
                }
                #if !os(macOS)
                if let message = store.downloadMessage {
                    Section(Platform.isMac ? "Installation" : "Fichier IPA") {
                        Text(message)
                        if store.downloadingAppID != nil {
                            ProgressView()
                            Button("Annuler le téléchargement", role: .cancel) { store.cancelDownload() }
                        }
                        if let file = store.downloadedFile, !Platform.isMac {
                            ShareLink("Partager ou enregistrer dans Fichiers", item: file)
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
                    Text("Applications · \(groups.count) · \(filteredApps.count) builds")
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Client \(AppBuildInfo.current.summary)")
                        if let server = store.serverInfo { Text("Serveur \(server.summary)") }
                    }
                    .font(.caption2.monospacedDigit())
                }
            }
            .navigationTitle("ServeIPA Client")
            .searchable(text: $searchText, prompt: "App, version ou identifiant")
            .refreshable { await store.refresh() }
            #if os(macOS)
            .safeAreaInset(edge: .bottom, spacing: 0) { statusCards }
            #endif
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button("Mettre à jour les apps installées", systemImage: "wand.and.sparkles") {
                        showsUpdateAll = true
                    }
                    .help("Télécharger et installer toutes les versions plus récentes du serveur")
                    .disabled(store.outdatedInstalledApps.isEmpty || store.downloadingAppID != nil || store.updateBatch != nil)
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
                    Button("Réglages", systemImage: "gear") { showsSettings = true }
                }
            }
            .sheet(isPresented: $showsSettings) { ClientSettings(store: store) }
            #if os(macOS)
            .confirmationDialog("Mettre à jour les apps installées ?", isPresented: $showsUpdateAll,
                                titleVisibility: .visible) {
                Button("Mettre à jour \(store.outdatedInstalledApps.count) app(s)") {
                    Task { await store.updateInstalledApps() }
                }
            } message: {
                Text("\(store.outdatedInstalledApps.map { "\($0.name) \($0.version) (\($0.build))" }.formatted()). Elles seront remplacées dans Applications ; relancez celles qui sont ouvertes.")
            }
            #endif
            .confirmationDialog("Installer cette app ?", isPresented: Binding(
                get: { appToInstall != nil }, set: { if !$0 { appToInstall = nil } }
            ), titleVisibility: .visible, presenting: appToInstall) { app in
                Button("Installer \(app.name)") {
                    appToInstall = nil
                    Task { await store.install(app) }
                }
            } message: { app in
                if app.isMac {
                    Text("Version \(app.version), build \(app.build). L’app sera installée dans Applications et remplacera la version présente.")
                } else {
                    Text("Version \(app.version), build \(app.build). iOS demandera confirmation. L’IPA doit être signé pour cet appareil.")
                }
            }
            .confirmationDialog("Supprimer cet IPA du serveur ?", isPresented: Binding(
                get: { appToDelete != nil }, set: { if !$0 { appToDelete = nil } }
            ), titleVisibility: .visible, presenting: appToDelete) { app in
                Button("Supprimer \(app.name) \(app.version) (\(app.build))", role: .destructive) {
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
            .task(id: scenePhase) {
                if scenePhase == .active { await store.monitor() }
            }
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
    /// Build du projet Xcode, s'il est plus récent que ce build et que la version installée.
    var projectBuild: Int?
    /// Une app ouvrable via le schéma d'URL de ce build est présente sur l'appareil (version inconnue).
    let isPresent: Bool
    let downloading: Bool
    let downloadDisabled: Bool
    let install: () -> Void
    let download: () -> Void
    let open: () -> Void
    let rebuild: () -> Void
    let rebuildDisabled: Bool
    let delete: () -> Void

    private var isLastInstalled: Bool { lastInstall?.appID == app.id }
    private var isNewer: Bool { isLatest && lastInstall?.isOlder(than: app) == true }

    var body: some View {
        HStack(spacing: 10) {
            if isLatest {
                AppIconView(url: iconURL)
            } else {
                Color.clear.frame(width: 36, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isLatest { Text(app.name).font(.headline).lineLimit(1) }
                    Text("\(app.version) (\(app.build))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if isLastInstalled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .accessibilityLabel("Dernière installation via ServeIPA")
                    }
                    if isPresent {
                        Image(systemName: Platform.isMac ? "desktopcomputer" : "iphone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("App présente sur cet appareil")
                    }
                    if let projectBuild {
                        Label("Build \(projectBuild)", systemImage: "arrow.up.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(.orange.opacity(0.18), in: .capsule)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .help("Le projet Xcode est au build \(projectBuild), plus récent que ce build (\(app.build)). Recompilez-le sur le Mac serveur.")
                            .accessibilityLabel("Projet plus récent : build \(projectBuild)")
                    }
                    if isNewer {
                        Text("Nouveau")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint, in: .capsule)
                            .foregroundStyle(.white)
                            .accessibilityLabel("Plus récent que la dernière installation")
                    }
                }
                Text(details)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Section(app.bundleIdentifier) {
                    if !Platform.isMac {
                        Button(downloading ? "Téléchargement…" : "Télécharger le fichier IPA",
                               systemImage: "arrow.down.doc", action: download)
                            .disabled(downloadDisabled)
                    }
                    if Platform.isMac ? isPresent : app.launchURL != nil {
                        Button("Ouvrir l’app", systemImage: "arrow.up.forward.app", action: open)
                    }
                }
                Button("Recompiler sur le Mac", systemImage: "hammer", action: rebuild)
                    .disabled(rebuildDisabled)
                Button("Supprimer du serveur", systemImage: "trash", role: .destructive, action: delete)
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            Button(Platform.isMac ? "Installer dans Applications" : "Installer",
                   systemImage: "square.and.arrow.down", action: install)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(Platform.isMac && downloadDisabled)
        }
        .padding(.vertical, 1)
    }

    /// Date · taille · iOS minimum · nom du dossier s’il diffère du nom de l’app.
    private var details: String {
        var parts: [String] = []
        if let date = app.date { parts.append(Self.shortDate(date)) }
        parts.append(ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file))
        if let minimum = app.minimumOSVersion { parts.append("\(app.isMac ? "macOS" : "iOS") \(minimum)+") }
        if isNewer, let lastInstall { parts.append("installé : \(lastInstall.build)") }
        if olderCount > 0 { parts.append(olderCount == 1 ? "1 ancien" : "\(olderCount) anciens") }
        if app.displayName != app.name { parts.append(app.displayName) }
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
        return date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits).hour().minute())
    }
}

/// Avancement d'une compilation lancée sur le Mac : étape en cours, succès ou échec.
private struct RebuildStatusRow: View {
    let job: RebuildJob
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            switch job.state {
            case "succeeded":
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            case "failed":
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.title3)
            default:
                ProgressView()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(job.app) · \(job.platform)")
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(job.state == "failed" ? Color.red : Color.secondary)
                    .lineLimit(4)
            }
            Spacer(minLength: 0)
            if job.state != "running" {
                Button("Fermer", systemImage: "xmark.circle.fill", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.smooth, value: job)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch job.state {
        case "succeeded": "Terminé — le nouveau build est dans la liste."
        case "failed": job.error ?? "La compilation a échoué."
        default: job.step
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
                Section("À propos") {
                    LabeledContent("Client", value: AppBuildInfo.current.summary)
                    LabeledContent("Serveur", value: store.serverInfo?.summary ?? "Non communiqué")
                }
            }
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
        .frame(minWidth: 420, minHeight: 320)
        #endif
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
