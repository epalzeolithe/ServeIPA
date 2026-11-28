import Foundation

/// Dates git et numéros de build d'un projet : dernier commit de la branche courante et dernier push de sa branche distante.
nonisolated struct ProjectGitDates: Equatable, Sendable {
    var lastCommit: Date?
    /// Git ne garde la date d'un push que sur la machine qui l'a fait : nil si ce Mac n'a rien poussé.
    var lastPush: Date?
    /// Numéro de build de l'app dans le commit concerné, quand il est connu.
    var commitBuild: Int?
    var pushBuild: Int?

    static func read(project: URL) -> ProjectGitDates {
        let folder = project.deletingLastPathComponent()
        var info = ProjectGitDates()
        guard let head = git(["log", "-1", "--format=%H%x09%ct"], in: folder)?
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t"),
              head.count == 2, let seconds = TimeInterval(head[1]) else { return info }
        let commit = String(head[0])
        info.lastCommit = Date(timeIntervalSince1970: seconds)
        rememberBuild(of: commit, in: folder)
        info.commitBuild = CommittedBuild.read(revision: commit, project: project)
        if let upstream = git(["rev-parse", "--symbolic-full-name", "@{upstream}"], in: folder)?
            .trimmingCharacters(in: .whitespacesAndNewlines), upstream.hasPrefix("refs/"),
           let reflog = git(["log", "-g", "-n", "200", "--date=unix", "--format=%H%x09%gd%x09%gs", upstream, "--"],
                            in: folder),
           let push = lastPush(reflog: reflog) {
            info.lastPush = push.date
            info.pushBuild = CommittedBuild.read(revision: push.revision, project: project)
        }
        return info
    }

    /// Première ligne « commit<tab>ref@{secondes}<tab>update by push » d'un reflog, listé du plus récent au plus
    /// ancien.
    static func lastPush(reflog: String) -> (revision: String, date: Date)? {
        for line in reflog.split(separator: "\n") where line.hasSuffix("\tupdate by push") {
            if let revision = line.split(separator: "\t").first,
               let match = line.firstMatch(of: #/@\{(\d+)\}/#), let seconds = TimeInterval(match.1) {
                return (String(revision), Date(timeIntervalSince1970: seconds))
            }
        }
        return nil
    }

    /// Beaucoup de projets ne suivent pas `.build-number` dans git. Quand le dossier n'a aucune modification et que
    /// le compteur correspond exactement à ses sources, son numéro est celui du commit courant : il est retenu.
    private static func rememberBuild(of commit: String, in folder: URL) {
        guard CommittedBuild.rememberedBuild(commit) == nil,
              let state = try? String(contentsOf: folder.appending(path: ".build-number"), encoding: .utf8) else { return }
        let fields = state.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let number = Int(fields[1]),
              git(["status", "--porcelain", "--", "."], in: folder)?.isEmpty == true,
              // Calcul neuf : une empreinte réutilisée pourrait dater d'avant la dernière modification.
              SourceFingerprint.compute(folder: folder) == String(fields[0]) else { return }
        CommittedBuild.remember(build: number, for: commit)
    }

    /// Sortie d'une commande git en lecture seule ; nil si elle échoue (dossier hors dépôt, par exemple).
    static func git(_ arguments: [String], in folder: URL) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path, "--no-optional-locks"] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// Numéro de build d'une app tel qu'il était dans un commit donné.
nonisolated enum CommittedBuild {
    private static let defaultsKey = "commitBuilds"
    private static let maximumRemembered = 500
    private static let lock = NSLock()
    /// Ce que contient un commit ne change pas : lu une seule fois par lancement.
    nonisolated(unsafe) private static var cache: [String: Int?] = [:]

    static func read(revision: String, project: URL) -> Int? {
        let key = "\(project.path)@\(revision)"
        var content = lock.withLock { cache[key] }
        if content == nil {
            let read = contents(revision: revision, project: project)
            lock.withLock { cache[key] = .some(read) }
            content = .some(read)
        }
        return content.flatMap { $0 } ?? rememberedBuild(revision)
    }

    static func rememberedBuild(_ commit: String) -> Int? {
        UserDefaults.standard.dictionary(forKey: defaultsKey)?[commit] as? Int
    }

    static func remember(build: Int, for commit: String) {
        lock.withLock {
            var builds = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
            if builds.count >= maximumRemembered, let any = builds.keys.first { builds[any] = nil }
            builds[commit] = build
            UserDefaults.standard.set(builds, forKey: defaultsKey)
        }
    }

    /// Même ordre que `ProjectBuildNumber` : `.build-number`, `BuildNumber.swift`, puis `CURRENT_PROJECT_VERSION`.
    /// Ce dernier est ignoré quand le projet a un compteur : sa valeur n'est alors pas celle des builds.
    private static func contents(revision: String, project: URL) -> Int? {
        let folder = project.deletingLastPathComponent()
        let show = { (path: String) in ProjectGitDates.git(["show", "\(revision):./\(path)"], in: folder) }

        let files = ProjectGitDates.git(["ls-tree", "-r", "--name-only", revision, "--", "."], in: folder)?
            .split(separator: "\n").map(String.init) ?? []
        let counter = files.first {
            ($0 as NSString).lastPathComponent == "BuildNumber.swift" && $0.split(separator: "/").count <= 2
        }
        var build = show(".build-number").flatMap { text -> Int? in
            let fields = text.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 ? Int(fields[1]) : nil
        }
        if build == nil, let counter, let text = show(counter),
           let match = text.firstMatch(of: #/current\s*=\s*(\d+)/#) {
            build = Int(match.1)
        }
        let hasCounter = counter != nil
            || FileManager.default.fileExists(atPath: folder.appending(path: ".build-number").path)
        if build == nil, !hasCounter, let settings = show("\(project.lastPathComponent)/project.pbxproj") {
            build = ProjectBuildNumber.currentProjectVersions(in: settings).max()
        }
        return build
    }
}
