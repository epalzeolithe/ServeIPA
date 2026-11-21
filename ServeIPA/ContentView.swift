import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: IPAStore
    @State private var buildToDelete: IPABuild?
    @State private var showsCleanConfirmation = false
    @State private var platform: IPABuild.Platform = .iOS
    @State private var showsProjectScan = false

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
                    Text("\(platform.rawValue) (\(store.builds.filter { $0.platform == platform }.count))")
                        .tag(platform)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)
            BuildList(
                builds: store.builds.filter { $0.platform == platform },
                platform: platform,
                selection: $store.selectedBuildID,
                oldBuildCount: store.oldBuildCount,
                rebuildingBundleID: store.rebuildingBundleID,
                rebuildStatus: store.rebuildStatus,
                rebuildAction: { build in Task { await store.rebuild(build) } },
                deleteAction: { buildToDelete = $0 },
                cleanAction: { showsCleanConfirmation = true }
            )
        }
        .frame(minWidth: 720, minHeight: 460)
        .toolbar {
            ToolbarItem {
                Button("Scanner les projets Xcode…", systemImage: "hammer") {
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
                Button("Nettoyer les anciennes versions", systemImage: "sparkles") {
                    showsCleanConfirmation = true
                }
                .disabled(store.oldBuildCount == 0 || store.isScanning)
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
        .confirmationDialog(
            "Supprimer toutes les anciennes versions ?",
            isPresented: $showsCleanConfirmation,
            titleVisibility: .visible
        ) {
            Button("Supprimer \(store.oldBuildCount) ancien(s) build(s)", role: .destructive) {
                Task { await store.cleanOldVersions() }
            }
        } message: {
            Text("Seul le build le plus récent de chaque app est conservé. Les dossiers des autres sont supprimés définitivement du disque.")
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
    @Binding var selection: String?
    let oldBuildCount: Int
    let rebuildingBundleID: String?
    let rebuildStatus: String?
    let rebuildAction: (IPABuild) -> Void
    let deleteAction: (IPABuild) -> Void
    let cleanAction: () -> Void
    @State private var expandedGroups: Set<String> = []

    private var groups: [BuildGroup] { BuildGroup.grouping(builds) }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) },
            set: { if $0 { expandedGroups.insert(id) } else { expandedGroups.remove(id) } }
        )
    }

    /// Lance l'app macOS exportée.
    private func launch(_ build: IPABuild) {
        NSWorkspace.shared.openApplication(at: build.fileURL, configuration: NSWorkspace.OpenConfiguration())
    }

    private func row(for build: IPABuild, isLatest: Bool, olderCount: Int = 0) -> some View {
        BuildRow(build: build, isLatest: isLatest, olderCount: olderCount)
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
                    Divider()
                }
                Button(build.platform == .macOS ? "Recompiler et exporter l’app" : "Recompiler et exporter l’IPA", systemImage: "hammer") {
                    rebuildAction(build)
                }
                .disabled(rebuildingBundleID != nil)
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
                platform == .iOS ? "Aucun IPA" : "Aucune app macOS",
                systemImage: "shippingbox",
                description: Text(platform == .iOS
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
                        Text("\(groups.count) apps · \(builds.count) builds")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Nettoyer les anciennes versions", systemImage: "sparkles", action: cleanAction)
                            .disabled(oldBuildCount == 0)
                        if let selected = builds.first(where: { $0.id == selection }) {
                            Button("Recompiler", systemImage: "hammer") {
                                rebuildAction(selected)
                            }
                            .disabled(rebuildingBundleID != nil)
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

    /// Date · taille · iOS minimum · anciens builds · nom du dossier s'il diffère du nom de l'app.
    private var details: String {
        var parts: [String] = []
        if let date = build.folderDate { parts.append(Self.shortDate(date)) }
        parts.append(ByteCountFormatter.string(fromByteCount: build.size, countStyle: .file))
        if let minimum = build.minimumOSVersion { parts.append("\(build.platform == .macOS ? "macOS" : "iOS") \(minimum)+") }
        if olderCount > 0 { parts.append(olderCount == 1 ? "1 ancien" : "\(olderCount) anciens") }
        if build.displayName != build.name { parts.append(build.displayName) }
        if isLatest { parts.append(build.bundleIdentifier) }
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
                ? try? Data(contentsOf: url.appending(path: entry))
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
        .frame(width: 520, height: 560)
        .padding()
    }
}

#Preview {
    ContentView(store: IPAStore())
}
