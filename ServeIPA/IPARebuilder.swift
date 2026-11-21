import Foundation

/// Recompile une app depuis son projet Xcode (sous le dossier Dev) puis exporte l'IPA
/// dans le dossier des IPA : archive Release pour les appareils enregistrés (export « debugging »).
enum IPARebuilder {
    enum RebuildError: LocalizedError {
        case projectNotFound(String, searched: String)
        case unreadableFolder(String)
        case schemeNotFound(String)
        case failed(step: String, details: String)
        case ipaMissing
        case macAppMissing
        case platformUnsupported(String, String)

        var errorDescription: String? {
            switch self {
            case .projectNotFound(let id, let searched):
                String(localized: "Aucun projet Xcode trouvé pour « \(id) » dans « \(searched) ». Vérifiez le dossier des projets dans les Réglages.")
            case .unreadableFolder(let path):
                String(localized: "Le dossier « \(path) » est inaccessible. Choisissez-le dans les Réglages (Dossier des projets) pour autoriser l’accès.")
            case .schemeNotFound(let project):
                String(localized: "Aucun scheme trouvé dans le projet « \(project) ».")
            case .failed(let step, let details):
                String(localized: "Échec de l’étape « \(step) ».\n\(details)")
            case .platformUnsupported(let scheme, let platform):
                String(localized: "« \(scheme) » ne prend pas en charge \(platform).")
            case .macAppMissing:
                String(localized: "L’export macOS s’est terminé sans produire d’app.")
            case .ipaMissing:
                String(localized: "L’export s’est terminé sans produire d’IPA.")
            }
        }
    }

    /// Recompile et exporte l'IPA (iOS) ou l'app (macOS) ; retourne le dossier d'export créé dans `ipaRoot`.
    /// Si `project` est fourni (choisi par l'utilisateur), la recherche dans `devRoot` est sautée.
    nonisolated static func rebuild(
        bundleIdentifier: String?,
        appName: String,
        project projectOverride: URL? = nil,
        devRoot: URL,
        ipaRoot: URL,
        platform: IPABuild.Platform,
        progress: @Sendable (String) -> Void
    ) async throws -> URL {
        progress(String(localized: "Recherche du projet…"))
        let project: URL
        if let projectOverride {
            project = projectOverride
        } else if let bundleIdentifier {
            project = try findProject(bundleIdentifier: bundleIdentifier, appName: appName, devRoot: devRoot, ipaRoot: ipaRoot)
        } else {
            throw RebuildError.projectNotFound(appName, searched: devRoot.path)
        }
        let projectName = project.deletingPathExtension().lastPathComponent
        let scheme = try listSchemes(project: project).first { $0 == projectName || $0 == appName }
            ?? listSchemes(project: project).first
            ?? { throw RebuildError.schemeNotFound(projectName) }()

        let work = FileManager.default.temporaryDirectory
            .appending(path: "ServeIPA-rebuild-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let platforms = supportedPlatforms(project: project, scheme: scheme, bundleIdentifier: bundleIdentifier)
        let required = platform == .macOS ? "macosx" : "iphoneos"
        // Un projet dont les plateformes sont illisibles est tenté tel quel.
        guard platforms.isEmpty || platforms.contains(required) else {
            throw RebuildError.platformUnsupported(scheme, platform.rawValue)
        }

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
        // Les apps macOS vont dans un dossier distinct suffixé « -macos ».
        let folderName = "\(scheme)\(platform == .macOS ? "-macos" : "") \(stamp.string(from: Date()))"
        let exportDirectory = ipaRoot.appending(path: folderName, directoryHint: .isDirectory)
        do {
            try await archiveAndExport(project: project, scheme: scheme,
                                       destination: platform == .macOS ? "generic/platform=macOS" : "generic/platform=iOS",
                                       label: platform.rawValue, work: work, exportPath: exportDirectory, progress: progress)
            let exported = (try? FileManager.default.contentsOfDirectory(atPath: exportDirectory.path)) ?? []
            switch platform {
            case .iOS:
                guard exported.contains(where: { $0.lowercased().hasSuffix(".ipa") }) else { throw RebuildError.ipaMissing }
            case .macOS:
                guard exported.contains(where: { $0.hasSuffix(".app") }) else { throw RebuildError.macAppMissing }
            }
        } catch {
            try? FileManager.default.removeItem(at: exportDirectory)
            throw error
        }
        return exportDirectory
    }

    /// Archive Release puis export « debugging » (appareils enregistrés) pour une plateforme.
    nonisolated private static func archiveAndExport(
        project: URL,
        scheme: String,
        destination: String,
        label: String,
        work: URL,
        exportPath: URL,
        progress: @Sendable (String) -> Void
    ) async throws {
        let archive = work.appending(path: "\(scheme)-\(label).xcarchive")
        progress(String(localized: "Compilation \(label) (Release)…"))
        try await run(step: String(localized: "archive \(label)"), log: work.appending(path: "archive-\(label).log"), arguments: [
            "-project", project.path,
            "-scheme", scheme,
            "-configuration", "Release",
            "-destination", destination,
            "-archivePath", archive.path,
            "-allowProvisioningUpdates",
            "archive"
        ])

        let optionsURL = work.appending(path: "ExportOptions-\(label).plist")
        var options: [String: Any] = [
            "destination": "export",
            "method": "debugging",
            "signingStyle": "automatic",
            "stripSwiftSymbols": true,
            "thinning": "<none>"
        ]
        if let team = archiveTeamID(archive) { options["teamID"] = team }
        try PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0).write(to: optionsURL)

        progress(String(localized: "Export de l’archive \(label)…"))
        try await run(step: String(localized: "export \(label)"), log: work.appending(path: "export-\(label).log"), arguments: [
            "-exportArchive",
            "-archivePath", archive.path,
            "-exportPath", exportPath.path,
            "-exportOptionsPlist", optionsURL.path,
            "-allowProvisioningUpdates"
        ])
    }

    /// Plateformes (iphoneos, macosx…) prises en charge par la cible de ce bundle, en Release.
    nonisolated private static func supportedPlatforms(project: URL, scheme: String, bundleIdentifier: String?) -> Set<String> {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = ["-showBuildSettings", "-json", "-project", project.path, "-scheme", scheme, "-configuration", "Release"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let targets = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let settings = targets.compactMap { $0["buildSettings"] as? [String: String] }
        // Sans identifiant connu (projet choisi à la main), on réunit les plateformes de toutes les cibles.
        let matching = bundleIdentifier.map { id in settings.filter { $0["PRODUCT_BUNDLE_IDENTIFIER"] == id } } ?? settings
        return Set(matching.flatMap { ($0["SUPPORTED_PLATFORMS"] ?? "").split(separator: " ").map(String.init) })
    }

    /// Cherche le projet dont une cible utilise cet identifiant de bundle (2 niveaux sous `devRoot`).
    nonisolated static func findProject(bundleIdentifier: String, appName: String, devRoot: URL, ipaRoot: URL) throws -> URL {
        guard (try? FileManager.default.contentsOfDirectory(atPath: devRoot.path)) != nil else {
            throw RebuildError.unreadableFolder(devRoot.path)
        }
        let skipped: Set<String> = ["old", "build", "Pods", "DerivedData", "node_modules", "SourcePackages"]
        let ipaPath = ipaRoot.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: devRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw RebuildError.unreadableFolder(devRoot.path) }

        let escaped = NSRegularExpression.escapedPattern(for: bundleIdentifier)
        let pattern = try NSRegularExpression(pattern: "PRODUCT_BUNDLE_IDENTIFIER = \"?\(escaped)\"?;")
        var matches: [URL] = []
        var allProjects: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > 3 || skipped.contains(url.lastPathComponent) || url.standardizedFileURL.path == ipaPath {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "xcodeproj" { allProjects.append(url) }
            guard url.pathExtension == "xcodeproj",
                  let text = try? String(contentsOf: url.appending(path: "project.pbxproj"), encoding: .utf8),
                  pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
            matches.append(url)
        }
        let preferred = matches.first { $0.deletingPathExtension().lastPathComponent == appName }
        // L'identifiant du build a pu changer depuis son export (ex. ancien identifiant « devplaceholder… ») :
        // à défaut, on retient le projet qui porte le nom de l'app.
        let normalize = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let byName = allProjects.first { normalize($0.deletingPathExtension().lastPathComponent) == normalize(appName) }
        guard let project = preferred ?? matches.first ?? byName else { throw RebuildError.projectNotFound(bundleIdentifier, searched: devRoot.path) }
        return project
    }

    nonisolated static func listSchemes(project: URL) throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = ["-list", "-json", "-project", project.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let schemes = (object?["project"] as? [String: Any])?["schemes"] as? [String]
        return schemes ?? []
    }

    nonisolated private static func archiveTeamID(_ archive: URL) -> String? {
        guard let data = try? Data(contentsOf: archive.appending(path: "Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (info["ApplicationProperties"] as? [String: Any])?["Team"] as? String
    }

    /// Lance xcodebuild en écrivant sa sortie dans `log` ; en cas d'échec, remonte les dernières erreurs.
    nonisolated private static func run(step: String, log: URL, arguments: [String]) async throws {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else {
            let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            let errors = lines.filter { $0.contains("error:") }
            let details = (errors.isEmpty ? lines.suffix(8) : errors.suffix(5)).joined(separator: "\n")
            throw RebuildError.failed(step: step, details: details)
        }
    }
}
