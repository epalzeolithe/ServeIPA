import Foundation

/// Prompts que rClaude fait exécuter en ce moment, vus depuis ce Mac : lancés ici (en local ou reçus par SSH)
/// ou envoyés d'ici vers un autre hôte. Un prompt qui tourne entièrement sur d'autres machines n'est pas visible.
nonisolated enum PromptActivity {
    /// Noms des projets rClaude d'après la liste des commandes en cours. rClaude les écrit dans la consigne qu'il
    /// ajoute à `claude -p`.
    static func projects(in commands: String) -> [String] {
        var names: Set<String> = []
        for line in commands.split(separator: "\n") where line.contains("claude -p") {
            if let match = line.firstMatch(of: #/Contexte rClaude : ce prompt concerne le projet « (.+?) »/#) {
                names.insert(String(match.1))
            }
        }
        return names.sorted()
    }

    /// Vrai si un projet en cours porte le nom de l'app (nom, nom du dossier d'export ou fin de l'identifiant).
    /// Casse, espaces et ponctuation sont ignorés.
    static func concerns(_ projects: [String], names: [String], bundleIdentifier: String) -> Bool {
        let normalize = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let identifier = bundleIdentifier.split(separator: ".").last.map(String.init) ?? ""
        let candidates = Set((names + [identifier]).map(normalize)).subtracting([""])
        return projects.contains { candidates.contains(normalize($0)) }
    }

    /// Vrai si un prompt interdit de compiler cette app. ServeIPA et son client partagent leurs sources : un prompt
    /// sur l'un bloque aussi l'autre.
    static func blocksCompilation(_ projects: [String], names: [String], bundleIdentifier: String) -> Bool {
        let family = ["ServeIPA", "ServeIPAClient"]
        let isOwn = concerns(family, names: names, bundleIdentifier: bundleIdentifier)
        return concerns(projects, names: isOwn ? names + family : names, bundleIdentifier: bundleIdentifier)
    }

    /// Commandes de tous les processus. La locale UTF-8 évite que `ps` n'échappe les guillemets et les accents.
    static func commands() -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "command="]
        process.environment = ["LC_ALL": "en_US.UTF-8"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
