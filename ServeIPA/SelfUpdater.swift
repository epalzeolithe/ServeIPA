import AppKit
import Foundation

/// Mise à jour de ServeIPA par lui-même : recompilation de son propre projet (macOS, Release), remplacement de
/// l'app installée puis relance.
///
/// Une app ne peut pas se remplacer pendant qu'elle tourne : un petit script détaché attend la fin de ce
/// processus, installe la nouvelle version (l'ancienne est gardée de côté et restaurée en cas d'échec) et la relance.
enum SelfUpdater {
    enum UpdateError: LocalizedError {
        case appMissing(URL)
        case wrongApp(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .appMissing(let folder):
                String(localized: "Aucune app ServeIPA dans l’export « \(folder.lastPathComponent) ».")
            case .wrongApp(let identifier):
                String(localized: "L’app compilée (« \(identifier) ») n’est pas ServeIPA : installation annulée.")
            case .launchFailed(let message):
                String(localized: "Impossible de lancer l’installation : \(message)")
            }
        }
    }

    /// App en cours d'exécution.
    static var runningApp: URL { Bundle.main.bundleURL.standardizedFileURL }

    /// Vrai si ServeIPA tourne depuis un dossier de compilation (lancé depuis Xcode).
    static var runsFromBuildFolder: Bool {
        let path = runningApp.path
        return path.contains("/DerivedData/") || path.contains("/Build/Products/") || path.hasPrefix(NSTemporaryDirectory())
    }

    /// Emplacement où installer la nouvelle version : à la place de l'app actuelle, ou dans /Applications
    /// si ServeIPA tourne depuis un dossier de compilation.
    static var installLocation: URL {
        runsFromBuildFolder
            ? URL(fileURLWithPath: "/Applications", isDirectory: true).appending(path: runningApp.lastPathComponent)
            : runningApp
    }

    /// L'app produite par l'export macOS, après vérification qu'il s'agit bien de ServeIPA.
    nonisolated static func exportedApp(in folder: URL) throws -> URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let name = names.first(where: { $0.hasSuffix(".app") }) else { throw UpdateError.appMissing(folder) }
        let app = folder.appending(path: name, directoryHint: .isDirectory)
        let identifier = Bundle(url: app)?.bundleIdentifier ?? "?"
        guard identifier == Bundle.main.bundleIdentifier else { throw UpdateError.wrongApp(identifier) }
        return app
    }

    /// Lance le script d'installation détaché puis quitte ServeIPA ; le script relance la nouvelle version.
    static func installAndRelaunch(_ newApp: URL, to destination: URL) throws {
        // Arguments passés au script (jamais interpolés dans son texte) : PID, nouvelle app, destination.
        let script = #"""
        pid="$1"; new="$2"; dest="$3"; backup="$dest.ancienne"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done
        rm -rf "$backup"
        if [ -e "$dest" ]; then mv "$dest" "$backup" || exit 1; fi
        if ditto "$new" "$dest"; then
            rm -rf "$backup"
        else
            rm -rf "$dest"
            [ -e "$backup" ] && mv "$backup" "$dest"
        fi
        open "$dest"
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "serveipa-update",
                             String(ProcessInfo.processInfo.processIdentifier), newApp.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.launchFailed(error.localizedDescription)
        }
        // Le script attend la fin de ce processus pour remplacer l'app.
        NSApplication.shared.terminate(nil)
    }
}
