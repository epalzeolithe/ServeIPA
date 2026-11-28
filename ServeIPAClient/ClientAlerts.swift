import Foundation
#if os(macOS)
import AppKit
#endif

/// Familles de notifications, activables séparément dans les Réglages (propres à l'appareil).
nonisolated enum NotificationKind: String, CaseIterable {
    case jobs, releases, serverUpdate, failures, installs, connection

    var key: String { "notify.\(rawValue)" }
    /// La perte de connexion est fréquente hors du réseau : elle est à activer soi-même.
    var enabledByDefault: Bool { self != .connection }
    var isEnabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? enabledByDefault }

    var title: String {
        switch self {
        case .jobs: "Fin de mes compilations"
        case .releases: "Nouvelles releases et nouvelles apps"
        case .serverUpdate: "Mise à jour du serveur disponible"
        case .failures: "Échecs des autres travaux du Mac"
        case .installs: "Installations en arrière-plan"
        case .connection: "Serveur injoignable ou de retour"
        }
    }

    /// Familles proposées sur cet appareil : le suivi des installations n'existe que sur Mac.
    static var available: [NotificationKind] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { $0 != .installs }
        #endif
    }
}

/// Comparaison du catalogue avec les releases déjà vues.
nonisolated enum ReleaseWatch {
    struct Changes {
        var updates: [RemoteApp] = []
        var additions: [RemoteApp] = []
        /// Repère de la release la plus récente vue, par identifiant de bundle.
        var known: [String: String]
    }

    /// `latest` : dernière release de chaque app. Sans relevé précédent, rien n'est signalé.
    static func compare(known: [String: String]?, latest: [RemoteApp]) -> Changes {
        var changes = Changes(known: known ?? [:])
        for app in latest {
            // La date du dossier d'export croît à chaque compilation, même à numéro de build égal.
            let marker = app.date ?? app.build
            let previous = changes.known[app.bundleIdentifier]
            if known != nil {
                if let previous {
                    if marker.compare(previous, options: .numeric) == .orderedDescending { changes.updates.append(app) }
                } else {
                    changes.additions.append(app)
                }
            }
            // Supprimer la dernière release ne fait pas reculer le repère.
            if previous.map({ marker.compare($0, options: .numeric) == .orderedDescending }) ?? true {
                changes.known[app.bundleIdentifier] = marker
            }
        }
        return changes
    }
}

// MARK: - Événements notifiés

extension ClientStore {
    private static let knownReleasesKey = "knownReleases"
    private static let notifiedUpdateKey = "notifiedServerUpdate"
    private static let seenJobsKey = "seenJobs"

    /// Après un changement d'adresse : le nouveau serveur est découvert sans notifications.
    func resetAlerts() {
        for key in [Self.knownReleasesKey, Self.notifiedUpdateKey, Self.seenJobsKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        failedRefreshes = 0
        hasReachedServer = false
    }

    /// Releases apparues depuis le dernier relevé : celles qui mettent à jour une app installée, et les nouvelles apps.
    func announceReleases() {
        guard !apps.isEmpty else { return }
        let known = UserDefaults.standard.dictionary(forKey: Self.knownReleasesKey) as? [String: String]
        let changes = ReleaseWatch.compare(known: known, latest: AppGroup.grouping(apps).map(\.latest))
        UserDefaults.standard.set(changes.known, forKey: Self.knownReleasesKey)

        // Les compilations demandées d'ici ont déjà leur notification.
        let updates = changes.updates.filter { !ownBuiltApps.contains($0.name) && isNewerThanInstalled($0) }
        let additions = changes.additions.filter { !ownBuiltApps.contains($0.name) }
        ownBuiltApps.subtract((changes.updates + changes.additions).map(\.name))

        let describe = { (apps: [RemoteApp]) in apps.map { "\($0.name) (\($0.build))" }.formatted() }
        if !updates.isEmpty {
            ClientNotifications.shared.post(
                .releases, id: "updates",
                title: updates.count == 1 ? "Mise à jour disponible" : "\(updates.count) mises à jour disponibles",
                body: describe(updates))
        }
        if !additions.isEmpty {
            ClientNotifications.shared.post(
                .releases, id: "additions",
                title: additions.count == 1 ? "Nouvelle app sur le serveur" : "\(additions.count) nouvelles apps",
                body: describe(additions))
        }
    }

    private func isNewerThanInstalled(_ app: RemoteApp) -> Bool {
        #if os(macOS)
        installedApp(app)?.record.isOlder(than: app) == true
        #else
        installHistory[app.bundleIdentifier]?.isOlder(than: app) == true
        #endif
    }

    /// Signale une fois chaque motif de mise à jour du serveur.
    func announceServerUpdate(_ detail: String?) {
        let defaults = UserDefaults.standard
        guard let detail else {
            defaults.removeObject(forKey: Self.notifiedUpdateKey)
            return
        }
        guard !isUpdatingServer, defaults.string(forKey: Self.notifiedUpdateKey) != detail else { return }
        defaults.set(detail, forKey: Self.notifiedUpdateKey)
        ClientNotifications.shared.post(.serverUpdate, id: "serverUpdate",
                                        title: "Mise à jour du serveur disponible", body: detail)
    }

    /// Échecs apparus sur le Mac pour des travaux non demandés d'ici (compilation de nuit, autre appareil).
    func announceForeignFailures(_ finished: [RebuildJob]) {
        let seen = UserDefaults.standard.stringArray(forKey: Self.seenJobsKey)
        UserDefaults.standard.set(Array((finished.map(\.id) + (seen ?? [])).prefix(100)), forKey: Self.seenJobsKey)
        // Au premier relevé, l'historique existant n'est pas signalé.
        guard let seen else { return }
        for job in finished where job.state == "failed" && !seen.contains(job.id) && !ownedJobIDs.contains(job.id) {
            ClientNotifications.shared.post(.failures, id: job.id, title: "\(job.app) : échec sur le Mac",
                                            body: job.detail)
        }
    }

    /// Appelé après chaque actualisation : signale la perte puis le retour du serveur.
    func announceConnection(reached: Bool) {
        // Pendant sa mise à jour, le serveur redémarre : c'est attendu.
        guard !isUpdatingServer else { return }
        if reached {
            if hasReachedServer, failedRefreshes >= 2 {
                ClientNotifications.shared.post(.connection, id: "connection", title: "Serveur de nouveau accessible",
                                                body: address)
            }
            hasReachedServer = true
            failedRefreshes = 0
        } else {
            failedRefreshes += 1
            // Deux échecs de suite, pour ignorer une coupure passagère.
            if hasReachedServer, failedRefreshes == 2 {
                ClientNotifications.shared.post(.connection, id: "connection", title: "Serveur injoignable",
                                                body: connectionMessage)
            }
        }
    }

    #if os(macOS)
    /// Étape d'une installation, utile seulement si l'on regarde ailleurs.
    func announceInstallation(_ title: String, _ body: String) {
        guard !NSApplication.shared.isActive else { return }
        ClientNotifications.shared.post(.installs, id: "install-\(title)", title: title, body: body)
    }
    #endif
}
