import Foundation

/// App trouvée par le scan du dossier des projets : un scheme d'un projet Xcode et l'app qu'il produit.
struct ScannedProject: Identifiable, Equatable, Sendable {
    /// Chemin du .xcodeproj suivi du scheme (un projet peut contenir plusieurs apps).
    let id: String
    let url: URL
    let name: String
    let scheme: String?
    let bundleIdentifier: String?
    let productName: String?
    /// Plateformes compilables (iOS si la cible accepte iphoneos, macOS si elle accepte macosx).
    let platforms: [IPABuild.Platform]
    /// Raison pour laquelle l'app ne peut pas être ajoutée (aucun scheme, aucune cible d'app…).
    let problem: String?

    /// Nom affiché : celui du produit (« NZBPad »), plutôt que celui du scheme (« MyApp »).
    var displayName: String { productName ?? scheme ?? name }

    /// Dossier du projet, relatif au dossier scanné (pour distinguer deux projets de même nom).
    func relativeFolder(to root: URL) -> String {
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard folder.hasPrefix(base) else { return folder }
        let relative = folder.dropFirst(base.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "." : relative
    }
}

/// Recherche les projets Xcode d'un dossier et lit, via xcodebuild, l'app que chacun produit.
enum XcodeProjectScanner {
    /// Dossiers jamais explorés (dépendances, produits de compilation, archives).
    nonisolated private static let skipped: Set<String> = ["old", "build", "Pods", "DerivedData", "node_modules", "SourcePackages", "Carthage"]

    /// Les .xcodeproj jusqu'à 3 niveaux sous `root`, hors du dossier des IPA.
    nonisolated static func findProjects(in root: URL, excluding ipaRoot: URL?) throws -> [URL] {
        guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            throw IPARebuilder.RebuildError.unreadableFolder(root.path)
        }
        let ipaPath = ipaRoot?.standardizedFileURL.path
        var projects: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > 3 || skipped.contains(url.lastPathComponent) || url.standardizedFileURL.path == ipaPath {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "xcodeproj" { projects.append(url) }
        }
        return projects.sorted {
            $0.deletingPathExtension().lastPathComponent
                .localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending
        }
    }

    /// Une entrée par scheme produisant une app (hors schemes de tests) ; un projet sans app donne une entrée
    /// signalant le problème.
    nonisolated static func inspect(_ project: URL) -> [ScannedProject] {
        let name = project.deletingPathExtension().lastPathComponent
        func result(scheme: String? = nil, bundle: String? = nil, product: String? = nil,
                    platforms: [IPABuild.Platform] = [], problem: String? = nil) -> ScannedProject {
            ScannedProject(id: project.standardizedFileURL.path + "|" + (scheme ?? ""), url: project, name: name,
                           scheme: scheme, bundleIdentifier: bundle, productName: product,
                           platforms: platforms, problem: problem)
        }

        let schemes = ((try? IPARebuilder.listSchemes(project: project)) ?? [])
            .filter { !$0.hasSuffix("Tests") && !$0.hasSuffix("UITests") }
        guard !schemes.isEmpty else {
            return [result(problem: String(localized: "Aucun scheme partagé"))]
        }
        var found: [ScannedProject] = []
        var seenBundles = Set<String>()
        for scheme in schemes {
            // La cible d'app du scheme : un produit .app, de préférence celle qui porte le nom du scheme.
            let apps = buildSettings(project: project, scheme: scheme).filter { $0["WRAPPER_EXTENSION"] == "app" }
            guard let app = apps.first(where: { $0["TARGET_NAME"] == scheme }) ?? apps.first else { continue }
            let bundle = app["PRODUCT_BUNDLE_IDENTIFIER"]
            // Deux schemes qui compilent la même app ne donnent qu'une entrée.
            if let bundle, !seenBundles.insert(bundle).inserted { continue }
            let supported = Set((app["SUPPORTED_PLATFORMS"] ?? "").split(separator: " ").map(String.init))
            var platforms: [IPABuild.Platform] = []
            if supported.contains("iphoneos") { platforms.append(.iOS) }
            if supported.contains("macosx") { platforms.append(.macOS) }
            found.append(result(scheme: scheme, bundle: bundle, product: app["PRODUCT_NAME"], platforms: platforms,
                                problem: platforms.isEmpty ? String(localized: "Ni iOS ni macOS") : nil))
        }
        return found.isEmpty ? [result(scheme: schemes.first, problem: String(localized: "Aucune cible d’application"))] : found
    }

    nonisolated private static func buildSettings(project: URL, scheme: String) -> [[String: String]] {
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
        return targets.compactMap { target in
            guard var settings = target["buildSettings"] as? [String: String] else { return nil }
            if settings["TARGET_NAME"] == nil, let name = target["target"] as? String { settings["TARGET_NAME"] = name }
            return settings
        }
    }
}
