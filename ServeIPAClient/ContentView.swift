import SwiftUI

struct ContentView: View {
    @State private var store = ClientStore()
    @State private var searchText = ""
    @State private var showsSettings = false
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
                if let message = store.downloadMessage {
                    Section("Fichier IPA") {
                        Text(message)
                        if store.downloadingAppID != nil {
                            ProgressView()
                            Button("Annuler le téléchargement", role: .cancel) { store.cancelDownload() }
                        }
                        if let file = store.downloadedFile {
                            ShareLink("Partager ou enregistrer dans Fichiers", item: file)
                        }
                    }
                }
                Section {
                    ForEach(filteredApps) { app in
                        AppRow(app: app, downloading: store.downloadingAppID == app.id,
                               downloadDisabled: store.downloadingAppID != nil,
                               install: { appToInstall = app },
                               download: { store.download(app) },
                               open: { Task { await store.openApp(app) } },
                               delete: { appToDelete = app })
                            .swipeActions(edge: .trailing) {
                                Button("Supprimer", systemImage: "trash", role: .destructive) {
                                    appToDelete = app
                                }
                            }
                    }
                    if filteredApps.isEmpty && store.isConnected {
                        ContentUnavailableView(searchText.isEmpty ? "Aucun IPA disponible" : "Aucun résultat",
                                               systemImage: "shippingbox",
                                               description: Text("Ajoutez des IPA dans les sous-dossiers du dossier choisi sur le Mac."))
                    }
                } header: {
                    Text("Applications · \(filteredApps.count)")
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Client \(AppBuildInfo.current.summary)")
                        if let server = store.serverInfo { Text("Serveur \(server.summary)") }
                    }
                    .font(.caption2.monospacedDigit())
                }
            }
            .navigationTitle("ServeIPA")
            .searchable(text: $searchText, prompt: "App, version ou identifiant")
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Réglages", systemImage: "gear") { showsSettings = true }
                }
            }
            .sheet(isPresented: $showsSettings) { ClientSettings(store: store) }
            .confirmationDialog("Installer cette app ?", isPresented: Binding(
                get: { appToInstall != nil }, set: { if !$0 { appToInstall = nil } }
            ), titleVisibility: .visible, presenting: appToInstall) { app in
                Button("Installer \(app.name)") {
                    appToInstall = nil
                    Task { await store.install(app) }
                }
            } message: { app in
                Text("Version \(app.version), build \(app.build). iOS demandera confirmation. L’IPA doit être signé pour cet appareil.")
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
    let downloading: Bool
    let downloadDisabled: Bool
    let install: () -> Void
    let download: () -> Void
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(app.name).font(.headline).lineLimit(1)
                    Text("\(app.version) (\(app.build))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Text(details)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Section(app.bundleIdentifier) {
                    Button(downloading ? "Téléchargement…" : "Télécharger le fichier IPA",
                           systemImage: "arrow.down.doc", action: download)
                        .disabled(downloadDisabled)
                    if app.launchURL != nil {
                        Button("Ouvrir l’app", systemImage: "arrow.up.forward.app", action: open)
                    }
                }
                Button("Supprimer du serveur", systemImage: "trash", role: .destructive, action: delete)
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            Button("Installer", systemImage: "square.and.arrow.down", action: install)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.vertical, 1)
    }

    /// Date · taille · iOS minimum · nom du dossier s’il diffère du nom de l’app.
    private var details: String {
        var parts: [String] = []
        if let date = app.date { parts.append(Self.shortDate(date)) }
        parts.append(ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file))
        if let minimum = app.minimumOSVersion { parts.append("iOS \(minimum)+") }
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
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
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
    }
}
