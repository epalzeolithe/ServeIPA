import AppKit
import Foundation

/// Mise à jour de ServeIPA par lui-même : recompilation de son propre projet (macOS, Release), remplacement de
/// l'app installée puis relance.
///
/// Une app ne peut pas se remplacer pendant qu'elle tourne : un petit script détaché attend la fin de ce
/// processus, installe la nouvelle version et la relance. L'ancienne version est gardée de côté jusqu'à ce que
/// la nouvelle réponde ; sinon elle est restaurée et relancée.
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

    /// Délai laissé à la nouvelle version pour répondre avant restauration.
    private static let healthTimeout = 90

    /// App en cours d'exécution.
    static var runningApp: URL { Bundle.main.bundleURL.standardizedFileURL }

    /// Fichier écrit par le script quand il restaure l'ancienne version.
    static var restoredMarker: URL {
        URL.libraryDirectory.appending(path: "Logs/ServeIPA/update-restored")
    }

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

    /// Vrai si les sources diffèrent de celles du dernier build : empreinte de Scripts/source-fingerprint.sh
    /// comparée à celle conservée dans `.build-number`. Vrai aussi si la comparaison est impossible.
    nonisolated static func sourcesChanged(in folder: URL) -> Bool {
        guard let state = try? String(contentsOf: folder.appending(path: ".build-number"), encoding: .utf8),
              let recorded = state.split(whereSeparator: \.isWhitespace).first else { return true }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [folder.appending(path: "Scripts/source-fingerprint.sh").path, folder.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return true }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != recorded
    }

    /// Arguments : PID à attendre, nouvelle app, destination, port de santé (vide si le serveur est arrêté),
    /// build attendu, identifiant du job, fichier témoin de restauration, délai en secondes.
    /// Ils sont passés au script, jamais interpolés dans son texte.
    nonisolated static let installScript = #"""
    pid="$1"; new="$2"; dest="$3"; port="$4"; build="$5"; job="$6"; marker="$7"; timeout="$8"
    backup="$dest.ancienne"

    start() { open "$dest" --args -startServerAfterUpdate "$serve"; }
    # Processus dont l'exécutable se trouve dans l'app installée.
    running() {
        ps -axww -o pid=,command= | P="$dest/Contents/MacOS/" awk \
            '{ id = $1; sub(/^ *[0-9]+ +/, ""); if (index($0, ENVIRON["P"]) == 1) print id }'
    }
    restore() {
        for id in $(running); do kill "$id" 2>/dev/null; done
        sleep 2
        for id in $(running); do kill -9 "$id" 2>/dev/null; done
        rm -rf "$dest"
        if [ -e "$backup" ]; then mv "$backup" "$dest"; fi
        mkdir -p "$(dirname "$marker")"
        printf '%s %s\n' "$job" "$build" > "$marker"
        start
        exit 1
    }
    if [ -n "$port" ]; then serve=YES; else serve=NO; fi

    i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done
    # Une app qui n'a pas quitté n'est pas remplacée.
    if kill -0 "$pid" 2>/dev/null; then exit 1; fi
    rm -rf "$backup"
    if [ -e "$dest" ]; then mv "$dest" "$backup" || { start; exit 1; }; fi
    ditto "$new" "$dest" || restore
    start

    elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        sleep 1
        elapsed=$((elapsed+1))
        if [ -n "$port" ]; then
            # Le serveur doit répondre avec le nouveau numéro de build.
            if curl -fs --max-time 2 "http://127.0.0.1:$port/api/v1/health" \
                | grep -qF "\"serverBuild\":\"$build\""; then
                rm -rf "$backup"; exit 0
            fi
        elif [ $elapsed -ge 20 ]; then
            # Sans serveur à interroger, l'app doit encore tourner après 20 secondes.
            if [ -n "$(running)" ]; then rm -rf "$backup"; exit 0; fi
            restore
        fi
    done
    restore
    """#

    /// Lance le script d'installation détaché puis quitte ServeIPA ; le script relance la nouvelle version.
    static func installAndRelaunch(_ newApp: URL, to destination: URL, expectedBuild: String,
                                   healthPort: UInt16?, jobID: String) throws {
        try? FileManager.default.removeItem(at: restoredMarker)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", installScript, "serveipa-update",
                             String(ProcessInfo.processInfo.processIdentifier), newApp.path, destination.path,
                             healthPort.map(String.init) ?? "", expectedBuild, jobID, restoredMarker.path,
                             String(healthTimeout)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.launchFailed(error.localizedDescription)
        }
        // Une feuille ou une alerte restée ouverte sur le Mac empêcherait de quitter.
        for window in NSApplication.shared.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        // Le script attend la fin de ce processus pour remplacer l'app.
        NSApplication.shared.terminate(nil)
    }
}
