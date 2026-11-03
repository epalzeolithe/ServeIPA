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
}
