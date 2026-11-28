import Foundation

struct IPABuild: Identifiable, Equatable, Sendable {
    enum Platform: String, CaseIterable, Sendable {
        case iOS
        case macOS
    }

    let id: String
    let fileURL: URL
    let relativePath: String
    let name: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let platforms: [String]
    let folderName: String
    let folderDate: String?
    let size: Int64
    var urlSchemes: [String] = []
    var minimumOSVersion: String? = nil
    /// Chemin de l'icône PNG dans l'archive IPA (nil si l'icône n'existe que dans Assets.car).
    var iconEntry: String? = nil
    /// iOS : fichier .ipa ; macOS : bundle .app (`fileURL`).
    var platform: Platform = .iOS
    /// macOS : date de l'exécutable, qui distingue deux compilations de même numéro.
    var builtAt: Date? = nil

    var displayName: String {
        let name = Self.folderDetails(folderName).name
        return platform == .macOS && name.hasSuffix("-macos") ? String(name.dropLast("-macos".count)) : name
    }

    nonisolated static func folderDetails(_ folder: String) -> (name: String, date: String?) {
        let pattern = #"^(.*?)[ _-]+(\d{4}-\d{2}-\d{2})[ _T]+(\d{2})[-:](\d{2})(?:[-:](\d{2}))?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: folder,
                range: NSRange(folder.startIndex..., in: folder)
              ),
              let nameRange = Range(match.range(at: 1), in: folder),
              let dayRange = Range(match.range(at: 2), in: folder),
              let hourRange = Range(match.range(at: 3), in: folder),
              let minuteRange = Range(match.range(at: 4), in: folder) else {
            return (folder, nil)
        }

        let second: String
        if let secondRange = Range(match.range(at: 5), in: folder) {
            second = String(folder[secondRange])
        } else {
            second = "00"
        }
        let rawName = String(folder[nameRange]).trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        let date = "\(folder[dayRange]) \(folder[hourRange]):\(folder[minuteRange]):\(second)"
        return (rawName.isEmpty ? folder : rawName, date)
    }
}

struct ScanIssue: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let message: String
}
