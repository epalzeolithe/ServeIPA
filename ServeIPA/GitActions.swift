import Foundation

/// Résultat d'une action git demandée par un client.
nonisolated struct GitActionResult: Sendable {
    let succeeded: Bool
    let message: String
}

/// Indexe et valide les changements du dossier d'un projet, puis les pousse au besoin.
nonisolated enum GitActions {
    /// Au-delà, la commande est interrompue (push sans réseau, hook bloqué).
    private static let timeout: TimeInterval = 90

    /// Seul le dossier du projet est concerné, même quand le dépôt est plus large. Sans changement, un push est
    /// tout de même tenté : des commits peuvent attendre.
    static func commit(folder: URL, message: String, push: Bool) -> GitActionResult {
        guard run(["rev-parse", "--is-inside-work-tree"], in: folder).status == 0 else {
            return GitActionResult(succeeded: false, message: "Ce projet n’est pas dans un dépôt git.")
        }
        let added = run(["add", "-A", "--", "."], in: folder)
        guard added.status == 0 else { return failure("L’indexation a échoué.", added.output) }

        var done = "Aucune modification à valider."
        // Code 0 : rien n'est indexé dans ce dossier.
        if run(["diff", "--cached", "--quiet", "--", "."], in: folder).status != 0 {
            let committed = run(["commit", "-m", message, "--", "."], in: folder)
            guard committed.status == 0 else { return failure("Le commit a échoué.", committed.output) }
            let hash = run(["rev-parse", "--short", "HEAD"], in: folder).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            done = "Commit \(hash) créé."
        }
        guard push else { return GitActionResult(succeeded: true, message: done) }
        let pushed = run(["push"], in: folder)
        guard pushed.status == 0 else { return failure("\(done) Le push a échoué.", pushed.output) }
        return GitActionResult(succeeded: true, message: "\(done) Push effectué.")
    }

    private static func failure(_ summary: String, _ output: String) -> GitActionResult {
        let details = String(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600))
        return GitActionResult(succeeded: false, message: details.isEmpty ? summary : "\(summary)\n\(details)")
    }

    private static func run(_ arguments: [String], in folder: URL) -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        // Personne ne peut répondre à une demande de mot de passe : la commande échoue au lieu d'attendre.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = environment["GIT_SSH_COMMAND"] ?? "ssh -oBatchMode=yes"
        // Les hooks et git-lfs peuvent venir de Homebrew.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
