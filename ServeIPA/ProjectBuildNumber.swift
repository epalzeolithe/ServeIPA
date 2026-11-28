import Foundation

/// Numéro de build courant d'un projet Xcode, lu dans ses sources (sans compiler).
enum ProjectBuildNumber {
    /// Dans l'ordre : `.build-number` (script de numérotation de ServeIPA), `BuildNumber.swift`
    /// (compteur incrémenté par le scheme), puis le plus grand `CURRENT_PROJECT_VERSION` du projet.
    /// `.build-number` n'avance qu'à la compilation : si les sources ont changé depuis, c'est le numéro que
    /// portera la prochaine compilation qui est retourné.
    nonisolated static func read(project: URL) -> Int? {
        let folder = project.deletingLastPathComponent()
        if let text = try? String(contentsOf: folder.appending(path: ".build-number"), encoding: .utf8) {
            // « empreinte numéro date »
            let fields = text.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, let number = Int(fields[1]) {
                let current = SourceFingerprint.current(folder: folder, state: text)
                return next(number: number, recorded: String(fields[0]), current: current)
            }
        }
        if let number = buildNumberSwift(in: folder) { return number }
        return ["project.pbxproj", "project.xcproj"]
            .compactMap { try? String(contentsOf: project.appending(path: $0), encoding: .utf8) }
            .flatMap(currentProjectVersions)
            .max()
    }

    /// Numéro inscrit dans `.build-number` : celui de la dernière compilation.
    nonisolated static func recorded(in folder: URL) -> Int? {
        guard let text = try? String(contentsOf: folder.appending(path: ".build-number"), encoding: .utf8) else { return nil }
        let fields = text.split(whereSeparator: \.isWhitespace)
        return fields.count >= 2 ? Int(fields[1]) : nil
    }

    /// Une empreinte illisible (script absent ou différent) laisse le numéro inscrit.
    nonisolated static func next(number: Int, recorded: String, current: String?) -> Int {
        guard let current, isFingerprint(recorded), current != recorded else { return number }
        return number + 1
    }

    nonisolated static func isFingerprint(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy(\.isHexDigit)
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

    nonisolated static func currentProjectVersions(in text: String) -> [Int] {
        text.matches(of: /CURRENT_PROJECT_VERSION"?\s*[=:]\s*"?(\d+)/).compactMap { Int($0.1) }
    }
}

/// Empreinte actuelle des sources d'un projet, calculée comme le fait son script `Scripts/build-number.sh` :
/// la commande `hash=$(…)` de ce script est exécutée seule, sans toucher au compteur.
nonisolated enum SourceFingerprint {
    /// Durée de réutilisation d'un calcul : les projets sont examinés toutes les 5 secondes.
    private static let lifetime: TimeInterval = 8
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [URL: (state: String, date: Date, value: String?)] = [:]

    /// `state` est le contenu de `.build-number` : une compilation le change et périme le calcul précédent.
    static func current(folder: URL, state: String) -> String? {
        let cached = lock.withLock { cache[folder] }
        if let cached, cached.state == state, Date().timeIntervalSince(cached.date) < lifetime { return cached.value }
        let value = compute(folder: folder)
        lock.withLock { cache[folder] = (state, Date(), value) }
        return value
    }

    /// La ligne `hash=` du script et ses suites (lignes terminées par « \\ »).
    static func command(in script: String) -> String? {
        var lines: [Substring] = []
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !lines.isEmpty || line.hasPrefix("hash=$(") else { continue }
            lines.append(line)
            if !line.hasSuffix("\\") { return lines.joined(separator: "\n") }
        }
        return nil
    }

    static func compute(folder: URL) -> String? {
        guard let script = try? String(contentsOf: folder.appending(path: "Scripts/build-number.sh"), encoding: .utf8),
              let command = command(in: script) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `-u` : une commande qui dépend d'une autre variable du script échoue au lieu de donner une empreinte fausse.
        process.arguments = ["-euc", command + "\nprintf %s \"$hash\""]
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PROJECT_DIR"] = folder.path
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = String(decoding: data, as: UTF8.self)
        return process.terminationStatus == 0 && ProjectBuildNumber.isFingerprint(value) ? value : nil
    }
}
