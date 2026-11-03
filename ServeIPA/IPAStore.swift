import AppKit
import Foundation
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
    }

    var builds: [IPABuild] = []
    var scanIssues: [ScanIssue] = []
    var serverState: ServerState = .stopped
    var serverURL: URL?
    var selectedBuildID: String?
    var folderURL: URL?
    var isScanning = false
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var startServerAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(startServerAutomatically, forKey: DefaultsKey.startServerAutomatically)
        }
    }

    let port: UInt16 = 8765
    private var server: OTAServer?
    private var isAccessingSecurityScopedFolder = false

    init() {
        UserDefaults.standard.register(defaults: [DefaultsKey.startServerAutomatically: true])
        startServerAutomatically = UserDefaults.standard.bool(forKey: DefaultsKey.startServerAutomatically)
        restoreFolder()
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
        let result = await Task.detached {
            Self.scan(folderURL)
        }.value
        builds = result.builds
        scanIssues = result.issues
        isScanning = false

        if let selectedBuildID, !builds.contains(where: { $0.id == selectedBuildID }) {
            self.selectedBuildID = nil
        }
        server?.update(builds: builds, rootURL: folderURL, publicURL: serverURL)
    }

    func delete(_ build: IPABuild) {
        guard let folderURL else { return }
        let rootURL = folderURL.standardizedFileURL
        let buildDirectoryURL = build.fileURL.deletingLastPathComponent().standardizedFileURL
        guard buildDirectoryURL != rootURL,
              buildDirectoryURL.pathComponents.starts(with: rootURL.pathComponents) else {
            serverState = .failed(String(localized: "Le répertoire de cet IPA ne peut pas être supprimé en toute sécurité."))
            return
        }

        do {
            try FileManager.default.removeItem(at: buildDirectoryURL)
            Task { await refresh() }
        } catch {
            serverState = .failed(error.localizedDescription)
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

    nonisolated private static func scan(_ rootURL: URL) -> (builds: [IPABuild], issues: [ScanIssue]) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isHiddenKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [ScanIssue(path: rootURL.path, message: String(localized: "Dossier inaccessible"))])
        }

        var builds: [IPABuild] = []
        var issues: [ScanIssue] = []
        for case let url as URL in enumerator {
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
                    minimumOSVersion: metadata.minimumOSVersion
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

private enum IPAMetadataReader {
    struct Metadata {
        let name: String
        let bundleIdentifier: String
        let version: String
        let build: String
        let platforms: [String]
        let urlSchemes: [String]
        let minimumOSVersion: String?
    }

    static func read(_ ipaURL: URL) throws -> Metadata {
        let listing = try runUnzip(arguments: ["-Z1", ipaURL.path])
        let pattern = #"^Payload/[^/]+\.app/Info\.plist$"#
        let candidates = listing.split(separator: "\n").map(String.init).filter {
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
            minimumOSVersion: info["MinimumOSVersion"] as? String
        )
    }

    private static func runUnzip(arguments: [String]) throws -> String {
        let data = try runUnzipData(arguments: arguments)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }

    private static func runUnzipData(arguments: [String]) throws -> Data {
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
