import Foundation
import Testing
@testable import ServeIPAClient

struct ServeIPAClientTests {
    @Test func acceptsHTTPSOrigin() throws {
        #expect(try ServerAddress.parse(" https://lucifer.tail0ad79c.ts.net/ ").absoluteString == ServerAddress.defaultValue)
        #expect(try ServerAddress.parse("https://server.example:8443").port == 8443)
    }

    @Test(arguments: ["http://server", "https://user:password@server", "https://server/api",
                      "https://server?secret=1", "https://server/#fragment", "", "not a URL"])
    func rejectsInvalidAddress(_ value: String) {
        #expect(throws: ClientError.self) { try ServerAddress.parse(value) }
    }

    @Test func rejectsManifestOnDifferentServer() throws {
        let base = try ServerAddress.parse(ServerAddress.defaultValue)
        let id = UUID().uuidString
        let ticket = InstallTicket(
            id: id,
            installURL: try #require(URL(string: "itms-services://?action=download-manifest&url=https://other.example/api/v1/sessions/\(id)/manifest")),
            downloadPath: "api/v1/sessions/\(id)/ipa"
        )
        #expect(throws: ClientError.self) { try ServerAddress.validate(ticket, server: base) }
    }

    @Test func validatesSessionLinks() throws {
        let base = try ServerAddress.parse(ServerAddress.defaultValue)
        let id = UUID().uuidString
        var install = URLComponents()
        install.scheme = "itms-services"
        install.host = ""
        install.queryItems = [
            URLQueryItem(name: "action", value: "download-manifest"),
            URLQueryItem(name: "url", value: base.appending(path: "api/v1/sessions/\(id)/manifest").absoluteString)
        ]
        let ticket = InstallTicket(id: id, installURL: try #require(install.url), downloadPath: "api/v1/sessions/\(id)/ipa")
        try ServerAddress.validate(ticket, server: base)
    }

    @Test func filtersUnsafeLaunchSchemes() throws {
        let json = """
        {"id":"app","name":"App","displayName":"App","bundleIdentifier":"example.app",
        "version":"1","build":"2","size":10,"platforms":["iPhoneOS"],
        "urlSchemes":["https","itms-services","com.googleusercontent.example","imetar"]}
        """
        let app = try JSONDecoder().decode(RemoteApp.self, from: Data(json.utf8))
        #expect(app.launchURL?.absoluteString == "imetar://")
    }

    private func release(version: String = "1.0", build: String, builtAt: Double? = nil) -> RemoteApp {
        RemoteApp(id: "release", name: "App", displayName: "App", bundleIdentifier: "test.app", version: version,
                  build: build, size: 1, platforms: [], urlSchemes: [], date: nil, minimumOSVersion: nil,
                  hasIcon: nil, platform: "macOS", projectBuild: nil, builtAt: builtAt)
    }

    @Test func recognisesTheInstalledRelease() {
        // Recompilation à numéro égal : l'identifiant de la release change, pas la version.
        let installed = InstallRecord(appID: "ancienne", version: "1.0", build: "161", date: Date())
        #expect(installed.matches(release(version: "1.0", build: "161")))
        #expect(!installed.matches(release(version: "1.0", build: "162")))
        #expect(!installed.matches(release(version: "2.0", build: "161")))
        // Mac : version lue sur le disque, avec la date de l'exécutable.
        let onDisk = InstallRecord(appID: "", version: "1.0", build: "161", date: Date(),
                                   builtAt: Date(timeIntervalSince1970: 1000))
        #expect(onDisk.matches(release(version: "1.0", build: "161", builtAt: 1000)))
        #expect(!onDisk.matches(release(version: "1.0", build: "161", builtAt: 2000)))
    }

    @Test func comparesProjectBuildsWithTheRunningOne() {
        #expect(ClientStore.isNewer(146, than: "145"))
        #expect(!ClientStore.isNewer(145, than: "145"))
        #expect(!ClientStore.isNewer(nil, than: "145"))
        #expect(!ClientStore.isNewer(146, than: "—"))
    }

    @Test func formatsAppDates() throws {
        let day = { (year: Int, month: Int, day: Int) in
            try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
        }
        let now = try day(2026, 11, 28)
        #expect(AppDate.short(try day(2026, 11, 25), now: now) == "25 nov 12:00")
        #expect(AppDate.short(try day(2025, 11, 25), now: now) == "25 nov 2025 12:00")
    }

    @Test func detectsNewerReleases() {
        let installed = InstallRecord(appID: "", version: "1.2", build: "10", date: Date(),
                                      builtAt: Date(timeIntervalSince1970: 1000))
        // La version prime sur le numéro de build.
        #expect(installed.isOlder(than: release(version: "2.0", build: "1")))
        #expect(!installed.isOlder(than: release(version: "1.1", build: "99")))
        #expect(installed.isOlder(than: release(version: "1.2", build: "11")))
        #expect(!installed.isOlder(than: release(version: "1.2", build: "9")))
        // À numéros égaux, la date de compilation départage, avec une tolérance.
        #expect(installed.isOlder(than: release(version: "1.2", build: "10", builtAt: 2000)))
        #expect(!installed.isOlder(than: release(version: "1.2", build: "10", builtAt: 1001)))
        #expect(!installed.isOlder(than: release(version: "1.2", build: "10", builtAt: 500)))
        #expect(!installed.isOlder(than: release(version: "1.2", build: "10")))
    }

    #if os(macOS)
    @Test func reportsOnlyReleasesNotSeenBefore() {
        let app = { (identifier: String, date: String) in
            RemoteApp(id: identifier + date, name: identifier, displayName: identifier, bundleIdentifier: identifier,
                      version: "1.0", build: "1", size: 1, platforms: [], urlSchemes: [], date: date,
                      minimumOSVersion: nil, hasIcon: nil, platform: nil, projectBuild: nil)
        }
        let first = ReleaseWatch.compare(known: nil, latest: [app("a", "2026-11-01 10:00:00")])
        #expect(first.updates.isEmpty && first.additions.isEmpty)

        let second = ReleaseWatch.compare(known: first.known,
                                          latest: [app("a", "2026-11-02 10:00:00"), app("b", "2026-11-02 11:00:00")])
        #expect(second.updates.map(\.name) == ["a"])
        #expect(second.additions.map(\.name) == ["b"])

        // Revenir à une release antérieure (suppression de la dernière) ne signale rien, ni son retour.
        let third = ReleaseWatch.compare(known: second.known, latest: [app("a", "2026-11-01 10:00:00")])
        #expect(third.updates.isEmpty && third.additions.isEmpty)
        let fourth = ReleaseWatch.compare(known: third.known, latest: [app("a", "2026-11-02 10:00:00")])
        #expect(fourth.updates.isEmpty)
    }

    @Test func detectsRClaudeRunningAPrompt() {
        let list = """
          100     1 /Applications/rClaude.app/Contents/MacOS/rClaude
          101   100 /usr/bin/ssh -p 22 drax@mac cd ~ || exit 97; claude -p --verbose
          200     1 /Applications/Autre.app/Contents/MacOS/Autre
          201   200 claude -p
          300     1 /Applications/rClaude.app/Contents/MacOS/rClaude
          301   300 /usr/local/bin/tailscale status --json
        """
        let rClaude = "com.epalzeolithe.rClaude"
        #expect(BusyApp.isBusy(bundleIdentifier: rClaude, pids: [100], processList: list))
        // Sans prompt en cours, ou pour une autre app, la mise à jour a lieu.
        #expect(!BusyApp.isBusy(bundleIdentifier: rClaude, pids: [300], processList: list))
        #expect(!BusyApp.isBusy(bundleIdentifier: "test.app", pids: [200], processList: list))
    }

    @Test func reportsWhyAnInstallationFails() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "ServeIPAClientTests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let app = root.appending(path: "source/Test.app")
        try manager.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.app", "CFBundleVersion": "2"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let archive = root.appending(path: "Test.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", app.path, archive.path]
        try zip.run()
        zip.waitUntilExit()
        let work = { (name: String) throws -> URL in
            let folder = root.appending(path: name)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        let extracted = try await ClientStore.extract(archive: archive, into: work("ok"), bundleIdentifier: "test.app")
        let destination = root.appending(path: "Installed.app")
        try ClientStore.replace(destination, with: extracted)
        #expect(ClientStore.installedInfo(destination)?.build == "2")

        await #expect(throws: InstallError.wrongApp(expected: "other.app", found: "test.app")) {
            try await ClientStore.extract(archive: archive, into: work("wrong"), bundleIdentifier: "other.app")
        }
        let broken = root.appending(path: "broken.zip")
        try Data("pas une archive".utf8).write(to: broken)
        await #expect(throws: InstallError.self) {
            try await ClientStore.extract(archive: broken, into: work("broken"), bundleIdentifier: "test.app")
        }
    }
    #endif
}
