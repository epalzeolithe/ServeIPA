import Foundation

// Même règle que dans ServeIPAClient/ClientInstaller.swift.

/// Apps qu'il ne faut pas quitter pendant qu'elles travaillent.
nonisolated enum BusyApp {
    /// rClaude lance chaque prompt dans un processus fils (`claude -p`, en local ou par SSH).
    static func isBusy(bundleIdentifier: String, pids: [Int32], processList: String) -> Bool {
        guard bundleIdentifier == "com.epalzeolithe.rClaude" else { return false }
        var children: [Int32: [(pid: Int32, command: Substring)]] = [:]
        for line in processList.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            children[parent, default: []].append((pid, fields[2]))
        }
        var pending = pids
        var seen: Set<Int32> = []
        while let parent = pending.popLast() {
            guard seen.insert(parent).inserted else { continue }
            for child in children[parent] ?? [] {
                if child.command.contains("claude -p") { return true }
                pending.append(child.pid)
            }
        }
        return false
    }

    /// Sortie de `ps` : PID, PID du parent et commande de chaque processus.
    static func processList() -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,ppid=,command="]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
