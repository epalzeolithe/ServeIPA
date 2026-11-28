import Foundation

/// Emplacements des projets Xcode retenus d'un passage à l'autre : les retrouver demande de parcourir le dossier
/// des projets, et la détection le fait toutes les quelques secondes. Réservé à cette détection ; une compilation
/// ou un commit relance toujours la recherche.
nonisolated enum ProjectLocator {
    /// Au-delà, la recherche est refaite : un projet a pu être ajouté, déplacé ou changer d'identifiant.
    static let foundLifetime: TimeInterval = 300
    /// Une app sans projet est recherchée de nouveau plus tôt.
    static let missingLifetime: TimeInterval = 60

    private struct Key: Hashable {
        let bundleIdentifier: String
        let appName: String
        let devRoot: URL
        let ipaRoot: URL
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: (project: URL?, date: Date)] = [:]

    static func project(bundleIdentifier: String, appName: String, devRoot: URL, ipaRoot: URL, now: Date = Date(),
                        search: () throws -> URL) -> URL? {
        let key = Key(bundleIdentifier: bundleIdentifier, appName: appName, devRoot: devRoot, ipaRoot: ipaRoot)
        if let entry = lock.withLock({ cache[key] }), isValid(entry.project, age: now.timeIntervalSince(entry.date)) {
            return entry.project
        }
        let project = try? search()
        lock.withLock { cache[key] = (project, now) }
        return project
    }

    private static func isValid(_ project: URL?, age: TimeInterval) -> Bool {
        guard let project else { return age < missingLifetime }
        // Un projet supprimé ou déplacé est recherché sans attendre.
        return age < foundLifetime && FileManager.default.fileExists(atPath: project.path)
    }

    static func find(bundleIdentifier: String, appName: String, devRoot: URL, ipaRoot: URL) -> URL? {
        project(bundleIdentifier: bundleIdentifier, appName: appName, devRoot: devRoot, ipaRoot: ipaRoot) {
            try IPARebuilder.findProject(bundleIdentifier: bundleIdentifier, appName: appName,
                                         devRoot: devRoot, ipaRoot: ipaRoot)
        }
    }
}
