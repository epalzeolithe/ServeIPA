import Foundation

/// Numéro de build courant d'un projet Xcode, lu dans ses sources (sans compiler).
enum ProjectBuildNumber {
    /// Dans l'ordre : `.build-number` (script de numérotation de ServeIPA), `BuildNumber.swift`
    /// (compteur incrémenté par le scheme), puis le plus grand `CURRENT_PROJECT_VERSION` du projet.
    nonisolated static func read(project: URL) -> Int? {
        let folder = project.deletingLastPathComponent()
        if let text = try? String(contentsOf: folder.appending(path: ".build-number"), encoding: .utf8) {
            // « empreinte numéro date »
            let fields = text.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, let number = Int(fields[1]) { return number }
        }
        if let number = buildNumberSwift(in: folder) { return number }
        return ["project.pbxproj", "project.xcproj"]
            .compactMap { try? String(contentsOf: project.appending(path: $0), encoding: .utf8) }
            .flatMap(currentProjectVersions)
            .max()
    }

    /// `static let current = 86` dans un fichier BuildNumber.swift (2 niveaux sous le dossier du projet).
    nonisolated private static func buildNumberSwift(in folder: URL) -> Int? {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator {
            if enumerator.level > 2 { enumerator.skipDescendants(); continue }
            guard url.lastPathComponent == "BuildNumber.swift",
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let match = text.firstMatch(of: /current\s*=\s*(\d+)/) else { continue }
            return Int(match.1)
        }
        return nil
    }

    nonisolated private static func currentProjectVersions(in text: String) -> [Int] {
        text.matches(of: /CURRENT_PROJECT_VERSION"?\s*[=:]\s*"?(\d+)/).compactMap { Int($0.1) }
    }
}
