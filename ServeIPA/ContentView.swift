import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: IPAStore
    @State private var buildToDelete: IPABuild?

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
            BuildList(
                builds: store.builds,
                selection: $store.selectedBuildID,
                deleteAction: { buildToDelete = $0 }
            )
        }
        .frame(minWidth: 720, minHeight: 460)
        .toolbar {
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

private struct BuildList: View {
    let builds: [IPABuild]
    @Binding var selection: String?
    let deleteAction: (IPABuild) -> Void

    var body: some View {
        if builds.isEmpty {
            ContentUnavailableView(
                "Aucun IPA",
                systemImage: "shippingbox",
                description: Text("Choisissez un dossier contenant des IPA dans ses sous-dossiers.")
            )
        } else {
            List(builds, selection: $selection) { build in
                BuildRow(
                    name: build.displayName,
                    date: build.folderDate ?? build.folderName,
                    applicationName: build.name,
                    bundleIdentifier: build.bundleIdentifier,
                    version: build.version,
                    buildNumber: build.build,
                    platforms: build.platforms,
                    size: build.size
                )
                .tag(build.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Supprimer", systemImage: "trash", role: .destructive) {
                        deleteAction(build)
                    }
                }
                .contextMenu {
                    Button("Afficher dans le Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([build.fileURL])
                    }
                    Divider()
                    Button("Supprimer", systemImage: "trash", role: .destructive) {
                        deleteAction(build)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("\(builds.count) IPA · ServeIPA \(AppBuildInfo.current.summary)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let selected = builds.first(where: { $0.id == selection }) {
                        Button("Afficher dans le Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([selected.fileURL])
                        }
                        Button("Supprimer", role: .destructive) {
                            deleteAction(selected)
                        }
                    }
                }
                .padding(10)
                .background(.bar)
            }
        }
    }
}

private struct BuildRow: View {
    let name: String
    let date: String
    let applicationName: String
    let bundleIdentifier: String
    let version: String
    let buildNumber: String
    let platforms: [String]
    let size: Int64

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.headline)
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                Text("\(applicationName) · \(bundleIdentifier)")
                    .foregroundStyle(.secondary)
                Text("Version \(version.isEmpty ? "—" : version) · Build \(buildNumber) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !platforms.isEmpty {
                    Text(platforms.formatted())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 5)
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
        .frame(width: 520, height: 440)
        .padding()
    }
}

#Preview {
    ContentView(store: IPAStore())
}
