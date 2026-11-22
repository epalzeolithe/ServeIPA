import SwiftUI

/// Fenêtre « Scanner les projets Xcode » : choix du dossier (mémorisé), scan, puis ajout des apps cochées.
struct ProjectScanView: View {
    @Bindable var store: IPAStore
    @Environment(\.dismiss) private var dismiss
    /// Clés `IPAStore.addKey` cochées.
    @State private var selection: Set<String> = []
    @State private var showsServed = false

    var body: some View {
        VStack(spacing: 0) {
            folderBar
            Divider()
            content
            if store.isAddingProjects || !addStates.isEmpty {
                buildBanner
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 460)
        .task {
            if store.scannedProjects.isEmpty, !store.isScanningProjects { await scan() }
        }
    }

    // MARK: Dossier

    private var folderBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dossier scanné").font(.caption).foregroundStyle(.secondary)
                Text(store.effectiveProjectsFolder?.path ?? "Aucun dossier choisi")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Changer…") {
                store.chooseProjectsFolder()
                Task { await scan() }
            }
            .disabled(store.isScanningProjects || store.isAddingProjects)
            Button("Scanner", systemImage: "arrow.clockwise") {
                Task { await scan() }
            }
            .disabled(store.effectiveProjectsFolder == nil || store.isScanningProjects || store.isAddingProjects)
        }
        .padding()
    }

    // MARK: Liste

    @ViewBuilder
    private var content: some View {
        if store.isScanningProjects {
            VStack(spacing: 10) {
                if let progress = store.projectScanProgress, progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .frame(maxWidth: 320)
                    Text("Lecture des projets : \(progress.done) sur \(progress.total)")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("Recherche des projets…").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.projectScanError {
            ContentUnavailableView("Scan impossible", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if store.scannedProjects.isEmpty {
            ContentUnavailableView("Aucun projet Xcode", systemImage: "magnifyingglass",
                                   description: Text("Aucun fichier .xcodeproj dans ce dossier (jusqu’à 3 niveaux)."))
        } else {
            List {
                if !candidates.isEmpty {
                    Section("À ajouter") {
                        ForEach(candidates) { row($0) }
                    }
                }
                if showsServed, !served.isEmpty {
                    Section("Déjà servies") {
                        ForEach(served) { row($0) }
                    }
                }
                if !unusable.isEmpty {
                    Section("Non compilables") {
                        ForEach(unusable) { row($0) }
                    }
                }
            }
        }
    }

    private func row(_ project: ScannedProject) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName).font(.headline)
                Text([project.scheme.flatMap { $0 == project.displayName ? nil : "scheme \($0)" },
                      project.bundleIdentifier, store.effectiveProjectsFolder.map { project.relativeFolder(to: $0) }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let problem = project.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                buildDetails(project)
            }
            Spacer()
            HStack(spacing: 8) {
                ForEach(project.platforms, id: \.self) { platform in
                    platformControl(project, platform)
                }
            }
        }
        .padding(.vertical, 4)
        .animation(.smooth, value: store.projectAddStates)
    }

    /// Étape en cours ou message d'échec, sous la ligne du projet.
    @ViewBuilder
    private func buildDetails(_ project: ScannedProject) -> some View {
        ForEach(project.platforms, id: \.self) { platform in
            switch store.projectAddStates[store.addKey(project, platform)] {
            case .building(let step):
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(platform.rawValue) · \(step)", systemImage: platform == .iOS ? "iphone" : "macbook")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                    ProgressView().progressViewStyle(.linear).frame(maxWidth: 280)
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            default:
                EmptyView()
            }
        }
    }

    // MARK: Bandeau de compilation

    private var addStates: [String: IPAStore.ProjectAddState] { store.projectAddStates }

    private var buildBanner: some View {
        let states = Array(addStates.values)
        let failed = states.filter { if case .failed = $0 { true } else { false } }.count
        let added = states.filter { $0 == .added }.count
        let finished = added + failed
        let current = addStates.first { if case .building = $0.value { true } else { false } }
        let currentName = current.flatMap { entry in
            store.scannedProjects.first { entry.key.hasPrefix($0.id + "|") }?.displayName
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if store.isAddingProjects {
                    ProgressView().controlSize(.small)
                    Text(currentName.map { "Compilation de \($0)" } ?? "Préparation…")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(min(finished + 1, states.count)) sur \(states.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(failed == 0 ? Color.green : Color.orange)
                    Text(failed == 0 ? "\(added) app(s) ajoutée(s)" : "\(added) ajoutée(s), \(failed) en échec")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
            }
            if store.isAddingProjects {
                ProgressView(value: Double(finished), total: Double(max(states.count, 1)))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder
    private func platformControl(_ project: ScannedProject, _ platform: IPABuild.Platform) -> some View {
        let key = store.addKey(project, platform)
        if let state = store.projectAddStates[key] {
            switch state {
            case .queued:
                chip(platform.rawValue, systemImage: "clock", tint: .secondary)
            case .building:
                chip(platform.rawValue, systemImage: nil, tint: .accentColor, spinner: true)
            case .added:
                chip(platform.rawValue, systemImage: "checkmark.circle.fill", tint: .green)
            case .failed(let message):
                chip(platform.rawValue, systemImage: "xmark.octagon.fill", tint: .red)
                    .help(message)
            }
        } else if store.isServed(project, platform: platform) {
            chip(platform.rawValue, systemImage: "checkmark.seal", tint: .secondary)
                .help("Un build de cette app est déjà dans le dossier des IPA.")
        } else {
            Toggle(platform.rawValue, isOn: Binding(
                get: { selection.contains(key) },
                set: { if $0 { selection.insert(key) } else { selection.remove(key) } }
            ))
            .toggleStyle(.checkbox)
            .disabled(store.isAddingProjects)
        }
    }

    /// Pastille d'état d'une plateforme.
    private func chip(_ title: String, systemImage: String?, tint: Color, spinner: Bool = false) -> some View {
        HStack(spacing: 5) {
            if spinner {
                ProgressView().controlSize(.mini)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: .capsule)
        .contentTransition(.symbolEffect(.replace))
    }

    // MARK: Pied

    private var footer: some View {
        HStack {
            Toggle("Afficher les apps déjà servies (\(served.count))", isOn: $showsServed)
                .toggleStyle(.checkbox)
            Spacer()
            if store.isAddingProjects {
                Text("Vous pouvez fermer cette fenêtre.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Fermer") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Ajouter \(pendingSelection.count) app(s)") {
                let items = pendingSelection
                selection.removeAll()
                Task { await store.addProjects(items) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(pendingSelection.isEmpty || store.isAddingProjects || store.rebuildingBundleID != nil
                      || store.folderURL == nil)
        }
        .padding()
    }

    // MARK: Données

    private func scan() async {
        selection.removeAll()
        await store.scanProjects()
    }

    /// Projets compilables dont au moins une plateforme n'est pas encore servie, ou en cours d'ajout
    /// (ils restent visibles avec leur état une fois ajoutés).
    private var candidates: [ScannedProject] {
        store.scannedProjects.filter { project in
            project.problem == nil && project.platforms.contains {
                !store.isServed(project, platform: $0) || store.projectAddStates[store.addKey(project, $0)] != nil
            }
        }
    }

    private var served: [ScannedProject] {
        let shown = Set(candidates.map(\.id))
        return store.scannedProjects.filter { project in
            project.problem == nil && !project.platforms.isEmpty && !shown.contains(project.id)
        }
    }

    private var unusable: [ScannedProject] {
        store.scannedProjects.filter { $0.problem != nil }
    }

    private var pendingSelection: [(project: ScannedProject, platform: IPABuild.Platform)] {
        store.scannedProjects.flatMap { project in
            project.platforms.compactMap { platform in
                selection.contains(store.addKey(project, platform)) ? (project, platform) : nil
            }
        }
    }
}
