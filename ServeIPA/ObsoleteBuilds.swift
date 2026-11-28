import Foundation

/// Releases remplacées par une compilation réussie.
nonisolated enum ObsoleteBuilds {
    /// Dossiers d'export à supprimer après la création de `export` : ceux des autres releases des apps qu'il
    /// contient (même identifiant de bundle, même plateforme).
    ///
    /// Aucun dossier n'est retenu si le nouvel export n'apparaît pas dans `builds`. Ne sont jamais retenus : la
    /// racine, un dossier hors de la racine, ni un dossier qui contient aussi une release à garder.
    static func folders(in builds: [IPABuild], supersededBy export: URL, root: URL) -> [URL] {
        let folder = { (build: IPABuild) in build.fileURL.deletingLastPathComponent().standardizedFileURL.path }
        let exportPath = export.standardizedFileURL.path
        let rootURL = root.standardizedFileURL
        let key = { (build: IPABuild) in "\(build.platform.rawValue)/\(build.bundleIdentifier)" }
        let replaced = Set(builds.filter { folder($0) == exportPath }.map(key))
        let obsolete = builds.filter { replaced.contains(key($0)) && folder($0) != exportPath }
        let obsoleteIDs = Set(obsolete.map(\.id))
        let protected = Set(builds.filter { !obsoleteIDs.contains($0.id) }.map(folder))
        return Set(obsolete.map(folder)).subtracting(protected)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter {
                let components = $0.standardizedFileURL.pathComponents
                return components.count > rootURL.pathComponents.count
                    && components.starts(with: rootURL.pathComponents)
            }
            .sorted { $0.path < $1.path }
    }
}
